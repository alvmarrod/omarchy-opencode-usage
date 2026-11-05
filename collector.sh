#!/usr/bin/bash
# OpenCode usage collector: emits one compact JSON doc to stdout.
#
# OpenCode v1 recorded per-message usage in the `message` table; v2 records it
# in `session_message` (type='assistant', model.providerID / model.id, and a
# tokens object with input/output/reasoning/cache). The schema is detected
# once and the same aggregation runs against either shape.
#
# OAuth credentials: OpenCode V2 no longer writes auth.json. Device/OAuth
# logins live in the `credential` table of opencode.db and are read read-only;
# value.access is preferred, value.key (plain API key) is accepted too.
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

if [[ ! -x $JQ ]]; then echo "collector.sh: jq not found" >&2; exit 1; fi
if [[ ! -x $SQLITE3 ]]; then echo "collector.sh: sqlite3 not found" >&2; exit 1; fi

# Belt and braces for direct runs; the real boundary is Service.qml's
# cleared environment (BASH_ENV is read at startup, so unset only protects
# children we spawn from here on).
export PATH="/usr/bin:/bin"
unset BASH_ENV ENV

: "${HOME:?collector.sh: HOME is not set}"
readonly DATA_ROOT="$HOME/.local/share/opencode"
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
# The 5H summary card is a rolling window; week/month stay calendar-aligned.
ROLLING_CUTOFF=$(( NOW_MS - 5 * 60 * 60 * 1000 ))
# Align the week/month windows with the 7/30 calendar-day series used by the
# panel (and by `opencode stats --days 7/30`), instead of rolling 7x24h.
WEEK_START_DATE=$("$DATE" -d '-6 days' +%F)
MONTH_START_DATE=$("$DATE" -d '-29 days' +%F)
CUTOFF=$(( $("$DATE" -d "$WEEK_START_DATE 00:00" +%s) * 1000 ))
MONTH_CUTOFF=$(( $("$DATE" -d "$MONTH_START_DATE 00:00" +%s) * 1000 ))

GO_MAX_BYTES=262144
# Producer-side bounds: top-N SQL caps keep output representative for heavy
# users; the final byte ceiling below fails closed as a backstop.
PROVIDER_ROW_LIMIT=128
MODEL_ROW_LIMIT=1000
COLLECTOR_MAX_BYTES=262144

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
  legacy_keys=$("$JQ" -c '[to_entries[] | select(.value.key) | .key]' "$AUTH_JSON" 2>/dev/null) || legacy_keys='[]'
  [[ -n $legacy_keys ]] || legacy_keys='[]'
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

# OpenCode v2 records per-message usage in session_message (model.providerID,
# model.id, no tokens.total); v1 wrote message (providerID, modelID,
# tokens.total). Same numbers, different JSON paths. The type filter is part
# of every v2 query, including the 7-day series.
USAGE_TABLE=message
PROVIDER_PATH="json_extract(data,'\$.providerID')"
MODEL_PATH="COALESCE(json_extract(data,'\$.modelID'),'?')"
TOKENS_EXPR="json_extract(data,'\$.tokens.total')"
EXTRA_WHERE=""
if [[ -r $DB ]] && [[ -n $("$SQLITE3" -readonly -cmd ".timeout 3000" "file:$DB?mode=ro" \
  "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_message' LIMIT 1;" 2>/dev/null) ]]; then
  USAGE_TABLE=session_message
  PROVIDER_PATH="json_extract(data,'\$.model.providerID')"
  MODEL_PATH="COALESCE(json_extract(data,'\$.model.id'),'?')"
  TOKENS_EXPR="(COALESCE(json_extract(data,'\$.tokens.input'),0)+COALESCE(json_extract(data,'\$.tokens.output'),0)+COALESCE(json_extract(data,'\$.tokens.reasoning'),0)+COALESCE(json_extract(data,'\$.tokens.cache.read'),0)+COALESCE(json_extract(data,'\$.tokens.cache.write'),0))"
  EXTRA_WHERE="AND type = 'assistant'"
fi

provider_rows() {
  local out
  [[ -r $DB ]] || { echo '[]'; return; }
  out=$("$SQLITE3" -readonly -cmd ".timeout 3000" -json "file:$DB?mode=ro" \
    "SELECT $PROVIDER_PATH AS pid,
            ROUND(SUM(CASE WHEN time_created > $ROLLING_CUTOFF THEN COALESCE($TOKENS_EXPR,0) ELSE 0 END)) AS tokens5h,
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE($TOKENS_EXPR,0) ELSE 0 END)) AS tokensMonth,
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE($TOKENS_EXPR,0) ELSE 0 END)) AS tokensWeek,
            ROUND(SUM(CASE WHEN time_created > $ROLLING_CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4) AS cost5h,
            ROUND(SUM(CASE WHEN time_created > $MONTH_CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4) AS costMonth,
            ROUND(SUM(CASE WHEN time_created > $CUTOFF THEN COALESCE(json_extract(data,'\$.cost'),0) ELSE 0 END),4) AS costWeek,
            COUNT(DISTINCT CASE WHEN time_created > $ROLLING_CUTOFF THEN $MODEL_PATH END) AS models5h,
            COUNT(DISTINCT CASE WHEN time_created > $CUTOFF THEN $MODEL_PATH END) AS modelsWeek,
            COUNT(DISTINCT CASE WHEN time_created > $MONTH_CUTOFF THEN $MODEL_PATH END) AS modelsMonth
     FROM $USAGE_TABLE
     WHERE $PROVIDER_PATH IS NOT NULL
       AND $PROVIDER_PATH != ''
       AND (json_extract(data,'\$.error') IS NULL
            OR COALESCE($TOKENS_EXPR,0) > 0
            OR COALESCE(json_extract(data,'\$.cost'),0) > 0)
       $EXTRA_WHERE
     GROUP BY 1 ORDER BY costWeek DESC LIMIT $PROVIDER_ROW_LIMIT;" 2>/dev/null) || out='[]'
  [[ -n $out ]] || out='[]'
  printf '%s' "$out"
}

model_rows() {
  local out
  [[ -r $DB ]] || { echo '[]'; return; }
  out=$("$SQLITE3" -readonly -cmd ".timeout 3000" -json "file:$DB?mode=ro" \
    "SELECT $PROVIDER_PATH AS provider,
            $MODEL_PATH AS model,
            date(time_created/1000,'unixepoch','localtime') AS date,
            ROUND(SUM(COALESCE($TOKENS_EXPR,0))) AS tokens,
            ROUND(SUM(COALESCE(json_extract(data,'\$.cost'),0)),4) AS cost
     FROM $USAGE_TABLE
     WHERE time_created > $CUTOFF
       AND $PROVIDER_PATH IS NOT NULL
       AND $PROVIDER_PATH != ''
       AND (json_extract(data,'\$.error') IS NULL
            OR COALESCE($TOKENS_EXPR,0) > 0
            OR COALESCE(json_extract(data,'\$.cost'),0) > 0)
       $EXTRA_WHERE
     GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT $MODEL_ROW_LIMIT;" 2>/dev/null) || out='[]'
  [[ -n $out ]] || out='[]'
  printf '%s' "$out"
}

provider_data=$(provider_rows)
model_data=$(model_rows)

providers=$("$JQ" -c '[.[] | {pid, tokens5h, tokensWeek, tokensMonth, cost5h, costWeek, costMonth, models5h, modelsWeek, modelsMonth, hasKey:false}]' <<<"$provider_data")

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
' <<<"$model_data")

providers=$(printf '%s\n%s\n%s\n%s\n' "$providers" "$models_map" "$legacy_keys" "$has_oauth" |
  "$JQ" -sc '
    .[0] as $providers
    | .[1] as $models
    | .[2] as $keys
    | .[3] as $hasOAuth
    | $providers
    | map(.hasKey = ((($hasOAuth == 1) and (.pid == "opencode" or .pid == "opencode-go"))
                    or (.pid as $id | any($keys[]; . == $id))))
    | map(.modelList = ($models[.pid].modelList // []))
  ')

gojson=$(collect_go "$go_key" "$go_hint")

recent='[]'
if [[ -r $DB ]]; then
  recent=$("$SQLITE3" -readonly -cmd ".timeout 3000" -json "file:$DB?mode=ro" \
    "WITH RECURSIVE days(d) AS (
       SELECT date('now','localtime','-6 days')
       UNION ALL
       SELECT date(d,'+1 day') FROM days WHERE d < date('now','localtime')
     )
     SELECT days.d AS date,
       ROUND(COALESCE(SUM(COALESCE($TOKENS_EXPR,0)),0)) AS tokens,
       ROUND(COALESCE(SUM(COALESCE(json_extract(data,'\$.cost'),0)),0),4) AS cost
     FROM days LEFT JOIN $USAGE_TABLE
       ON date($USAGE_TABLE.time_created/1000,'unixepoch','localtime') = days.d
      AND $PROVIDER_PATH IS NOT NULL
      AND $PROVIDER_PATH != '' $EXTRA_WHERE
     GROUP BY days.d ORDER BY 1;" 2>/dev/null) || recent='[]'
  [[ -n $recent ]] || recent='[]'
fi
if [[ -z $recent || $recent == '[]' ]]; then
  # No database/table yet (fresh install): same 7-day shape, all zeros.
  for i in 6 5 4 3 2 1 0; do
    d=$("$DATE" -d "-$i days" +%F)
    recent=$("$JQ" -c --arg d "$d" '. + [{date:$d,tokens:0,cost:0}]' <<<"$recent")
  done
fi

final=$(printf '%s\n%s\n%s\n' "$providers" "$gojson" "$recent" |
  "$JQ" -sc '
    .[0] as $providers
    | .[1] as $go
    | .[2] as $recentDays
    | {status:"ok",providers:$providers,go:$go,recentDays:$recentDays,updatedAt:(now|todateiso8601)}
  ')
size=$(printf '%s' "$final" | "$WC" -c)
if (( size > COLLECTOR_MAX_BYTES )); then
  echo "collector.sh: output exceeds $COLLECTOR_MAX_BYTES bytes" >&2
  exit 1
fi
printf '%s\n' "$final"
