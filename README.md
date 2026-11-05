# omarchy-opencode-usage

OpenCode usage widget for the Omarchy shell (Quickshell): 5H/7D/1M token,
cost, and model summaries, usage per configured provider (Zen, Go, Bedrock,
...), daily per-model breakdowns for the last 7 days, and OpenCode Go limit
windows via the go/v1/usage API.

Plugin ID: `io.github.alvmarrod.opencode-usage`

This repository continues the plugin with OpenCode V2 support:

- usage is read per message from `session_message` (the V1 `message` shape is
  still supported)
- OAuth device logins are read from the `credential` table in `opencode.db`
  instead of the removed V1 `auth.json` (plain API keys and `auth.json` are
  still supported)
- the 7/30-day windows are calendar-aligned with the panel's daily series and
  with `opencode stats`

## Install

Clone the repository into your Omarchy plugin directory and enable it:

    omarchy plugin add https://github.com/alvmarrod/omarchy-opencode-usage

The command validates the plugin, enables it, and asks which bar section to
place the widget in (default: right). For a non-interactive install that
enables the widget with the default section:

    omarchy plugin add https://github.com/alvmarrod/omarchy-opencode-usage --enable --yes

## Remove

Removes the plugin files and takes the bar widget with it:

    omarchy plugin remove io.github.alvmarrod.opencode-usage


## Dependencies

- `sqlite3` — reads OpenCode's local database (`~/.local/share/opencode/opencode.db`, read-only).
- `jq` — assembles the collector JSON output.
- `curl` — queries the OpenCode Go usage API (`https://opencode.ai/zen/go/v1/usage`).

Credentials: the collector reads the active `opencode` OAuth device
credential from the `credential` table (access token and expiry, read-only)
and sends it only to the official OpenCode Go usage endpoint. It never
prints the token and never writes to the database; token refresh remains
OpenCode's job. If the token has expired the widget reports `Login expired`
until OpenCode refreshes it. A legacy `~/.local/share/opencode/auth.json`
`opencode-go` key is used as a fallback.

All tool paths are absolute (nothing is resolved through `PATH`), and the
script runs under a cleared environment.

## Files

- `manifest.json` — Omarchy shell plugin manifest (schemaVersion 1)
- `Panel.qml` — bar widget entry point
- `Service.qml` — refresh service running `collector.sh` on a timer
- `Model.js` — formatting and normalization helpers
- `collector.sh` — collects per-message tokens/cost from OpenCode's database
  and Go limit windows

Edits under the installed plugin directory hot-reload; force a rescan with
`omarchy-shell shell rescanPlugins` if needed.

## Lineage

This is an independent continuation of:

- [Dahep/omarchy-plugin-opencode-usage](https://github.com/Dahep/omarchy-plugin-opencode-usage)
  — the original plugin
- [NiloyTheSpd/opencode-tracker](https://github.com/NiloyTheSpd/opencode-tracker)
  — the fork that added the hardened collector, the weekly budget, and related work

Both are credited under the MIT license. This repository is not a GitHub
fork of either project and is maintained independently.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the release history.

## License

MIT — see `LICENSE`.
