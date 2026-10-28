#!/usr/bin/bash
# OpenCode usage collector: emits one compact JSON doc to stdout.
#
# Data sources, in order of preference:
#   1. `opencode stats --json` (OpenCode V2 supported interface) for exact
#      per-provider/model token and cost totals plus daily windows.
#   2. Direct read of the V2 database (session_v2 + session_message), used
#      when the OpenCode background server is not reachable.
#   3. Direct read of the legacy V1 `message` table.
#
# OAuth credentials: OpenCode V2 no longer writes auth.json. Device/OAuth
# logins live in the `credential` table of opencode.db and are read read-only.
# auth.json is still honored as a legacy fallback.
#
# Supply-chain hardening (marketplace review):
# - Absolute tool paths only; nothing is resolved through PATH, so a
#   shadowed binary cannot intercept the collector. Service.qml additionally
#   launches this script with a pinned minimal PATH and --noprofile --norc.
# - Closed environment: only HOME (+TZ for sqlite localtime) and the
#   documented OPENCODE_* test overrides are honored; anything else is
#   ignored. Override paths must be absolute without parent traversal.
# - Bounded output: SQL row caps plus a final stdout byte ceiling, so a
#   huge database cannot blow up the QML-side buffer.
# - Whole-tree teardown: when started via setsid (Service.qml) with
#   COLLECTOR_PG_LEADER=1, TERM/INT/HUP stops the entire process group, so
#   curl/sqlite3 grandchildren cannot outlive the widget watchdog.
set -uo pipefail

readonly JQ=/usr/bin/jq
readonly SQLITE3=/usr/bin/sqlite3
readonly CURL=/usr/bin/curl
readonly DATE=/usr/bin/date
readonly MKTEMP=/usr/bin/mktemp
readonly HEAD=/usr/bin/head
readonly WC=/usr/bin/wc
readonly CHMOD=/usr/bin/chmod
readonly RM=/usr/bin/rm
readonly KILL=/usr/bin/kill
readonly TIMEOUT=/usr/bin/timeout

if [[ ! -x $JQ ]]; then echo "collector.sh: jq not found" >&2; exit 1; fi
if [[ ! -x $SQLITE3 ]]; then echo "collector.sh: sqlite3 not found" >&2; exit 1; fi

# Belt and braces for direct runs; the real boundary is Service.qml's
# cleared environment (BASH_ENV is read at startup, so unset only protects
# children we spawn from here on).
export PATH="/usr/bin:/bin"
unset BASH_ENV ENV

: "${HOME:?collector.sh: HOME is not set}"
readonly DATA_ROOT="$HOME/.local/share/opencode"
readonly SERVICE_JSON="$HOME/.local/state/opencode/service.json"
readonly GO_URL=https://opencode.ai/zen/go/v1/usage
AUTH_JSON="${OPENCODE_AUTH_JSON:-$DATA_ROOT/auth.json}"
DB="${OPENCODE_DB:-$DATA_ROOT/opencode.db}"

# Overrides (used by tests) must be absolute paths without parent traversal;
# /dev/null is allowed so tests can simulate "no auth file".
valid_override_path() {
  local p=$1
  [[ -n $p ]] || return 1
  [[ $p == /dev/null ]] && return 0
  [[ $p == /* ]] || return 1
  [[ $p != *".."* ]] || return 1
  return 0
}
if [[ -n "${OPENCODE_AUTH_JSON:-}" ]]; then
  valid_override_path "$AUTH_JSON" || { echo "collector.sh: refused auth path" >&2; exit 1; }
fi
if [[ -n "${OPENCODE_DB:-}" ]]; then
  valid_override_path "$DB" || { echo "collector.sh: refused db path" >&2; exit 1; }
fi
if [[ -n "${OPENCODE_BIN:-}" ]]; then
  valid_override_path "$OPENCODE_BIN" || { echo "collector.sh: refused opencode path" >&2; exit 1; }
  [[ -x $OPENCODE_BIN ]] || { echo "collector.sh: opencode binary not executable" >&2; exit 1; }
fi

# Whole-tree teardown. Only armed when our launcher confirms we lead our own
# process group (setsid + COLLECTOR_PG_LEADER=1); otherwise killing group $$
# could hit an unrelated foreground group, so direct test runs skip this.
# The handler removes temp files first, then SIGKILLs the group: KILL cannot
# be trapped or pended, so unlike a self-directed TERM this cannot re-trigger
# its own handler and loop — leader and curl/sqlite3 grandchildren all die.
if [[ "${COLLECTOR_PG_LEADER:-}" == "1" ]]; then
  trap 'rm -f "${tmpf:-}" "${hdrf:-}" 2>/dev/null; "$KILL" -KILL -- -$$ 2>/dev/null' TERM INT HUP
fi

NOW_MS=$(( $("$DATE" +%s) * 1000 ))
CUTOFF=$(( NOW_MS-604800000 ))
MONTH_CUTOFF=$(( NOW_MS-30*86400000 ))
WEEK_START=$("$DATE" -d '-6 days' +%F)

GO_MAX_BYTES=262144
# Producer-side bounds: top-N SQL caps keep output representative for heavy
# users; the final byte ceiling below fails closed as a backstop.
PROVIDER_ROW_LIMIT=128
MODEL_ROW_LIMIT=1000
COLLECTOR_MAX_BYTES=262144

# Day labels for the 7-day windows, newest first (index 0 = today).
dates_json='[]'
for i in 0 1 2 3 4 5 6; do
  d=$("$DATE" -d "-$i days" +%F)
  dates_json=$("$JQ" -c --arg d "$d" '. + [$d]' <<<"$dates_json")
done

# Absolute paths only: the collector never consults PATH to find opencode.
resolve_opencode() {
  local c
  if [[ -n "${OPENCODE_BIN:-}" ]]; then
    printf '%s' "$OPENCODE_BIN"
    return 0
  fi
  for c in "$HOME/.local/share/mise/shims/opencode" \
           "$HOME/.local/bin/opencode" \
           /usr/local/bin/opencode \
           /usr/bin/opencode; do
    if [[ -x $c ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}
opencode_bin=$(resolve_opencode) || opencode_bin=""

# OAuth device credential from the V2 database (read-only). auth.json is not
# written by OpenCode V2, so this is the primary key source now. API keys
# stored in the same table (value.key) are accepted as well.
oauth_access=""
oauth_expires=0
has_oauth=0
credential_json=""
if [[ -r $DB ]]; then
  credential_json=$("$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
    "SELECT value FROM credential WHERE integration_id='opencode' AND active=1 ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null) || credential_json=""
  if [[ -n $credential_json ]] && "$JQ" -e 'type == "object"' >/dev/null 2>&1 <<<"$credential_json"; then
    oauth_access=$("$JQ" -r '.access // .key // empty' <<<"$credential_json" 2>/dev/null) || oauth_access=""
    oauth_expires=$("$JQ" -r '.expires // 0' <<<"$credential_json" 2>/dev/null) || oauth_expires=0
    [[ $oauth_expires =~ ^[0-9]+$ ]] || oauth_expires=0
  fi
fi
[[ -n $oauth_access ]] && has_oauth=1

# Legacy auth.json keys (V1) and their provider ids.
legacy_keys='[]'
if [[ -r $AUTH_JSON ]]; then
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    legacy_keys=$("$JQ" -c --arg k "$k" '. + [$k]' <<<"$legacy_keys")
  done < <("$JQ" -r 'to_entries[] | select(.value.key) | .key' "$AUTH_JSON" 2>/dev/null)
fi

# Resolve the Go bearer token: OAuth first, then the legacy opencode-go key.
# An expired OAuth token is reported instead of sent, because OpenCode owns
# the refresh cycle and will rotate it on its next run.
go_key=""
go_hint=""
if [[ -n $oauth_access ]]; then
  if (( oauth_expires > 0 && oauth_expires < NOW_MS )); then
    go_hint="Login expired"
  else
    go_key=$oauth_access
  fi
fi
if [[ -z $go_key ]]; then
  legacy_go_key=$("$JQ" -r '.["opencode-go"].key // empty' "$AUTH_JSON" 2>/dev/null) || legacy_go_key=""
  if [[ -n $legacy_go_key ]]; then
    go_key=$legacy_go_key
    go_hint=""
  fi
fi

collect_go() {
  local k=${1:-} hint=${2:-} out code size
  if [[ -z $k ]]; then
    if [[ -n $hint ]]; then
      "$JQ" -cn --arg s "$hint" '{status:$s}'
    else
      echo '{"status":"No API key"}'
    fi
    return
  fi
  [[ -x $CURL ]] || { echo '{"status":"curl missing"}'; return; }
  tmpf=$("$MKTEMP") || { echo '{"status":"network error"}'; return; }
  hdrf=$("$MKTEMP") || { "$RM" -f "$tmpf"; echo '{"status":"network error"}'; return; }
  "$CHMOD" 600 "$tmpf" "$hdrf" 2>/dev/null
  trap '"$RM" -f "$tmpf" "$hdrf"' EXIT
  printf 'Authorization: Bearer %s\n' "$k" >"$hdrf"
  set +o pipefail
  "$CURL" -sS -m 10 -w $'\n%{http_code}' --header @"$hdrf" "$GO_URL" 2>/dev/null \
    | "$HEAD" -c $((GO_MAX_BYTES+1)) >"$tmpf"
  curl_stat=${PIPESTATUS[0]}
  set -o pipefail
  "$RM" -f "$hdrf" # bearer token no longer needed; trap remains as backstop
  size=$("$WC" -c <"$tmpf")
  if (( size > GO_MAX_BYTES )); then
    echo '{"status":"response too large"}'
    return
  fi
  if [[ $curl_stat != 0 ]]; then
    echo '{"status":"network error"}'
    return
  fi
  out=$(<"$tmpf")
  "$RM" -f "$tmpf"
  code=${out##*$'\n'}; out=${out%$'\n'*}
  [[ $code == 200 ]] || { "$JQ" -cn --arg s "HTTP $code" '{status:$s}'; return; }
  "$JQ" -e '.usage.rolling and .usage.weekly and .usage.monthly' >/dev/null 2>&1 <<<"$out" || { echo '{"status":"bad response"}'; return; }
  "$JQ" -c '{status:"ok",rolling:.usage.rolling,weekly:.usage.weekly,monthly:.usage.monthly}' <<<"$out"
}

run_stats() {
  local n=$1 out
  [[ -n $opencode_bin ]] || return 1
  out=$("$TIMEOUT" -k 2 6 "$opencode_bin" stats --days "$n" --models --json 2>/dev/null) || return 1
  [[ -n $out ]] || return 1
  "$JQ" -e '.tokens != null and .cost != null' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# Never make the widget start OpenCode's background server. If the recorded
# server pid is not alive, collect_stats() declines and the SQL fallback runs.
opencode_server_up() {
  local pid
  [[ -r $SERVICE_JSON ]] || return 1
  pid=$("$JQ" -r '.pid // 0' "$SERVICE_JSON" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && (( pid > 0 )) || return 1
  "$KILL" -0 "$pid" 2>/dev/null
}

# Primary path: OpenCode V2's supported stats interface. Eight calls (~3s on
# a 130MB database) stay well inside the Service.qml 30s watchdog; a 22s
# budget leaves room for the SQL fallback if the server is unhealthy.
collect_stats() {
  local days_json='[]' month_json='' n out
  [[ -n $opencode_bin ]] || return 1
  opencode_server_up || return 1
  SECONDS=0
  for n in 1 2 3 4 5 6 7 30; do
    (( SECONDS > 22 )) && return 1
    out=$(run_stats "$n") || return 1
    if (( n == 30 )); then
      month_json=$out
    else
      days_json=$("$JQ" -c --argjson d "$out" '. + [$d]' <<<"$days_json") || return 1
    fi
  done

  "$JQ" -n --argjson days "$days_json" --argjson month "$month_json" \
    --argjson dates "$dates_json" --argjson hasOAuth "$has_oauth" \
    --argjson legacyKeys "$legacy_keys" '
def toks:
  ((.tokens.input // 0) + (.tokens.output // 0) + (.tokens.reasoning // 0)
   + (.tokens.cache.read // 0) + (.tokens.cache.write // 0));
def keyof: ((.model.providerID // "unknown") + "\u001f" + (.model.id // "?"));
def mmap:
  [ .models[]? | {key: keyof, value: {tokens: toks, cost: (.cost // 0)}} ]
  | group_by(.key)
  | map({key: .[0].key, value: {
      tokens: (map(.value.tokens) | add // 0),
      cost: (map(.value.cost) | add // 0)
    }})
  | from_entries;
def total: {tokens: toks, cost: (.cost // 0), models: mmap};
def zero: {tokens: 0, cost: 0, models: {}};
def pidx($k): ($k | split("\u001f")[0]);
def midx($k): ($k | split("\u001f")[1]);
def nonneg: if . < 0 then 0 else . end;
def diffday($a; $b):
  {
    tokens: (($a.tokens - $b.tokens) | nonneg),
    cost: (($a.cost - $b.cost) | nonneg),
    models: (
      (($a.models | keys_unsorted) + ($b.models | keys_unsorted) | unique) as $ks
      | reduce $ks[] as $k ({};
          .[$k] = {
            tokens: ((($a.models[$k].tokens // 0) - ($b.models[$k].tokens // 0)) | nonneg),
            cost: ((($a.models[$k].cost // 0) - ($b.models[$k].cost // 0)) | nonneg)
          })
    )
  };
def psum($src; $pid; $field):
  ([ $src | to_entries[] | select(pidx(.key) == $pid) | .value[$field] ] | add // 0);
def r4: ((. * 10000) | round) / 10000;
def r0: round;

($days | map(total)) as $cum
| ($cum[6]) as $week
| ($month | total) as $mon
| [ range(0; 7) as $i | diffday($cum[$i]; (if $i == 0 then zero else $cum[$i - 1] end)) ] as $daily
| (($week.models | keys_unsorted) + ($mon.models | keys_unsorted) | unique) as $keys
| ([ $keys[] | pidx(.) ] | unique) as $pids
| [ $pids[] as $pid
    | {
        pid: $pid,
        tokensWeek: (psum($week.models; $pid; "tokens") | r0),
        costWeek: (psum($week.models; $pid; "cost") | r4),
        tokensMonth: (psum($mon.models; $pid; "tokens") | r0),
        costMonth: (psum($mon.models; $pid; "cost") | r4),
        hasKey: (($hasOAuth == 1 and ($pid == "opencode" or $pid == "opencode-go"))
                 or (($legacyKeys | index($pid)) != null)),
        modelList: (
          ([ $keys[] | select(pidx(.) == $pid) ] | unique) as $mks
          | [ $mks[] as $mk
              | {
                  modelName: midx($mk),
                  tokensWeek: (($week.models[$mk].tokens // 0) | r0),
                  costWeek: (($week.models[$mk].cost // 0) | r4),
                  daily: ([ range(0; 7) as $i
                            | { date: $dates[$i],
                                tokens: (($daily[$i].models[$mk].tokens // 0) | r0),
                                cost: (($daily[$i].models[$mk].cost // 0) | r4) }
                          ] | reverse)
                }
            ] | sort_by(-.tokensWeek)
        )
      }
  ] | sort_by(-.costWeek) as $providers
| [ range(0; 7) as $i
    | { date: $dates[$i],
        tokens: ($daily[$i].tokens | r0),
        cost: ($daily[$i].cost | r4) }
  ] | reverse as $recent
| { providers: $providers, recentDays: $recent }
'
}

# Fallback path: V2 database without the background server. Costs are exact
# (per assistant message); per-session token totals are distributed across
# days by that session's daily cost share, which is the closest offline
# approximation available because V2 no longer stores per-message tokens.
collect_sql_v2() {
  [[ -r $DB ]] || return 1
  local tables rows_json
  tables=$("$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('session_v2','session_message');" 2>/dev/null) || return 1
  [[ $tables == 2 ]] || return 1
  rows_json=$("$SQLITE3" -readonly -cmd ".timeout 3000" -json "file:$DB?mode=ro" "
    WITH s AS (
      SELECT id, model,
        tokens_input+tokens_output+tokens_reasoning+tokens_cache_read+tokens_cache_write AS tok
      FROM session_v2
    ), m AS (
      SELECT session_id,
        date(time_created/1000,'unixepoch','localtime') AS day,
        SUM(COALESCE(json_extract(data,'\$.cost'),0)) AS c,
        COUNT(*) AS n
      FROM session_message
      WHERE type='assistant' AND time_created > $MONTH_CUTOFF
      GROUP BY 1,2
    ), sc AS (
      SELECT session_id, SUM(c) AS tc, SUM(n) AS tn FROM m GROUP BY 1
    ), w AS (
      SELECT m.session_id, m.day, m.c,
        CASE WHEN sc.tc > 0 THEN m.c / sc.tc ELSE m.n * 1.0 / sc.tn END AS wt
      FROM m JOIN sc ON sc.session_id = m.session_id
    )
    SELECT COALESCE(json_extract(s.model,'\$.providerID'),'unknown') AS pid,
           COALESCE(json_extract(s.model,'\$.id'),'?') AS mid,
           w.day AS date,
           ROUND(SUM(s.tok * w.wt)) AS tokens,
           ROUND(SUM(w.c),4) AS cost
    FROM w JOIN s ON s.id = w.session_id
    GROUP BY 1,2,3 ORDER BY 5 DESC LIMIT $MODEL_ROW_LIMIT;" 2>/dev/null) || return 1

  "$JQ" -n --argjson rows "${rows_json:-[]}" --argjson dates "$dates_json" \
    --arg weekStart "$WEEK_START" --argjson hasOAuth "$has_oauth" \
    --argjson legacyKeys "$legacy_keys" '
def r4: ((. * 10000) | round) / 10000;
def r0: round;
($rows) as $rows
| ($rows | group_by(.pid)) as $pgs
| [ $pgs[] | . as $g
    | {
        pid: $g[0].pid,
        tokensWeek: ([$g[] | select(.date >= $weekStart) | .tokens] | add // 0 | r0),
        costWeek: ([$g[] | select(.date >= $weekStart) | .cost] | add // 0 | r4),
        tokensMonth: ([$g[] | .tokens] | add // 0 | r0),
        costMonth: ([$g[] | .cost] | add // 0 | r4),
        hasKey: (($hasOAuth == 1 and ($g[0].pid == "opencode" or $g[0].pid == "opencode-go"))
                 or (($legacyKeys | index($g[0].pid)) != null)),
        modelList: (
          ($g | group_by(.mid))
          | map(. as $mg | {
              modelName: $mg[0].mid,
              tokensWeek: ([$mg[] | select(.date >= $weekStart) | .tokens] | add // 0 | r0),
              costWeek: ([$mg[] | select(.date >= $weekStart) | .cost] | add // 0 | r4),
              daily: ([ range(0; 7) as $i
                        | ($dates[$i]) as $d
                        | { date: $d,
                            tokens: ([$mg[] | select(.date == $d) | .tokens] | add // 0 | r0),
                            cost: ([$mg[] | select(.date == $d) | .cost] | add // 0 | r4) }
                      ] | reverse)
            })
          | sort_by(-.tokensWeek)
        )
      }
  ] | sort_by(-.costWeek) as $providers
| [ range(0; 7) as $i
    | ($dates[$i]) as $d
    | { date: $d,
        tokens: ([$rows[] | select(.date == $d) | .tokens] | add // 0 | r0),
        cost: ([$rows[] | select(.date == $d) | .cost] | add // 0 | r4) }
  ] | reverse as $recent
| { providers: $providers, recentDays: $recent }
'
}

# Legacy V1 path: message table holds per-message token totals and auth.json
# holds provider API keys.
provider_rows() {
  [[ -r $DB ]] || return
  "$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
    "SELECT json_extract(data,'\$.providerID'),
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE(json_extract(data,'\$.tokens.total'),0) ELSE 0 END)),
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE(json_extract(data,'\$.tokens.total'),0) ELSE 0 END)),
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4),
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4)
     FROM message
     WHERE json_extract(data,'\$.providerID') IS NOT NULL
       AND json_extract(data,'\$.providerID') != ''
     GROUP BY 1 ORDER BY 5 DESC LIMIT $PROVIDER_ROW_LIMIT;" 2>/dev/null || true
}

model_rows() {
  [[ -r $DB ]] || return
  "$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
    "SELECT json_extract(data,'\$.providerID'),
            COALESCE(json_extract(data,'\$.modelID'),'?'),
            date(time_created/1000,'unixepoch','localtime'),
            ROUND(SUM(COALESCE(json_extract(data,'\$.tokens.total'),0))),
            ROUND(SUM(COALESCE(json_extract(data,'\$.cost'),0)),4)
     FROM message
     WHERE time_created > $CUTOFF
       AND json_extract(data,'\$.providerID') IS NOT NULL
       AND json_extract(data,'\$.providerID') != ''
     GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT $MODEL_ROW_LIMIT;" 2>/dev/null || true
}

collect_sql_v1() {
  [[ -r $DB ]] || return 1
  local has_message providers keys_json rows models_map recent
  has_message=$("$SQLITE3" -readonly "file:$DB?mode=ro" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='message';" 2>/dev/null) || return 1
  [[ $has_message == 1 ]] || return 1

  providers='[]'
  while IFS='|' read -r pid mo wk mc wc; do
    [[ -n $pid ]] || continue
    providers=$("$JQ" -c --arg id "$pid" --argjson mo "${mo:-0}" --argjson wk "${wk:-0}" \
      --argjson mc "${mc:-0}" --argjson wc "${wc:-0}" \
      '. + [{pid:$id,tokensWeek:$wk,tokensMonth:$mo,costWeek:$wc,costMonth:$mc,hasKey:false}]' <<<"$providers")
  done < <(provider_rows)

  keys_json='[]'
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    keys_json=$("$JQ" -c --arg k "$k" '. + [$k]' <<<"$keys_json")
  done < <("$JQ" -r 'to_entries[] | select(.value.key) | .key' "$AUTH_JSON" 2>/dev/null)

  rows='[]'
  while IFS='|' read -r pid mid d t c; do
    [[ -n $pid ]] || continue
    rows=$("$JQ" -c --arg p "$pid" --arg m "$mid" --arg d "$d" \
      --argjson t "${t:-0}" --argjson c "${c:-0}" \
      '. + [{provider:$p,model:$m,date:$d,tokens:$t,cost:$c}]' <<<"$rows")
  done < <(model_rows)

  models_map=$("$JQ" -c '
    group_by(.provider) | map(
      { key: .[0].provider
      , value: { modelList: (
          group_by(.model) | map(
            { modelName: .[0].model
            , tokensWeek: (map(.tokens) | add // 0)
            , costWeek: (map(.cost) | add // 0)
            , daily: (map({date: .date, tokens: .tokens, cost: .cost}) | sort_by(.date))
            }
          )
        )
      }
      }
    ) | from_entries
  ' <<<"$rows")

  providers=$("$JQ" -c --argjson keys "$keys_json" --argjson hasOAuth "$has_oauth" \
    'map(.hasKey = ((($hasOAuth == 1) and (.pid == "opencode" or .pid == "opencode-go"))
                    or (.pid as $id | any($keys[]; . == $id))))' <<<"$providers")
  providers=$("$JQ" -c --argjson models "$models_map" \
    'map(.modelList = ($models[.pid].modelList // []))' <<<"$providers")

  recent='[]'
  while IFS='|' read -r d t c; do
    [[ -n $d ]] || continue
    recent=$("$JQ" -c --arg d "$d" --argjson t "${t:-0}" --argjson c "${c:-0}" \
      '. + [{date:$d,tokens:$t,cost:$c}]' <<<"$recent")
  done < <("$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
    "WITH RECURSIVE days(d) AS (
       SELECT date('now','localtime','-6 days')
       UNION ALL
       SELECT date(d,'+1 day') FROM days WHERE d < date('now','localtime')
     )
     SELECT days.d,
       ROUND(COALESCE(SUM(COALESCE(json_extract(message.data,'\$.tokens.total'),0)),0)),
       ROUND(COALESCE(SUM(COALESCE(json_extract(message.data,'\$.cost'),0)),0),4)
     FROM days LEFT JOIN message
       ON date(message.time_created/1000,'unixepoch','localtime') = days.d
     GROUP BY days.d ORDER BY 1;" 2>/dev/null || true)
  if [[ -z $recent || $recent == '[]' ]]; then
    for i in 6 5 4 3 2 1 0; do
      d=$("$DATE" -d "-$i days" +%F)
      recent=$("$JQ" -c --arg d "$d" '. + [{date:$d,tokens:0,cost:0}]' <<<"$recent")
    done
  fi

  "$JQ" -cn --argjson providers "$providers" --argjson recentDays "$recent" \
    '{providers:$providers,recentDays:$recentDays}'
}

if data_json=$(collect_stats); then
  :
elif data_json=$(collect_sql_v2); then
  :
elif data_json=$(collect_sql_v1); then
  :
else
  echo "collector.sh: no usable OpenCode usage data" >&2
  exit 1
fi

gojson=$(collect_go "$go_key" "$go_hint")

final=$("$JQ" -cn --argjson data "$data_json" --argjson go "$gojson" \
  '{status:"ok",providers:$data.providers,go:$go,recentDays:$data.recentDays,updatedAt:(now|todateiso8601)}')
size=$(printf '%s' "$final" | "$WC" -c)
if (( size > COLLECTOR_MAX_BYTES )); then
  echo "collector.sh: output exceeds $COLLECTOR_MAX_BYTES bytes" >&2
  exit 1
fi
printf '%s\n' "$final"
