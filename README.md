# opencode-tracker

OpenCode usage widget for the Omarchy shell (Quickshell): token and cost
usage per configured provider (Zen, Go, Bedrock, ...) from OpenCode, daily
per-model breakdowns for the last 7 days, and OpenCode Go limit windows via
the go/v1/usage API.

Plugin ID: `io.github.thespd.opencode-tracker`

> This checkout is a local fork (`alvmarrod/opencode-tracker`) that adds
> OpenCode V2 support: usage comes from `opencode stats --json`, and OAuth
> device logins are read from the `credential` table in `opencode.db`
> instead of the removed V1 `auth.json`. Legacy V1 databases and
> `auth.json` keys still work as fallbacks.

## Install

Clone the repository into your Omarchy plugin directory and enable it:

    omarchy plugin add https://github.com/alvmarrod/opencode-tracker

The command validates the plugin, enables it, and asks which bar section to
place the widget in (default: right). For a non-interactive install that
enables the widget with the default section:

    omarchy plugin add https://github.com/alvmarrod/opencode-tracker --enable --yes

## Remove

Removes the plugin files and takes the bar widget with it:

    omarchy plugin remove io.github.thespd.opencode-tracker


## Dependencies

- `opencode` — the OpenCode CLI (v2). The collector prefers
  `opencode stats --days N --models --json`, OpenCode's supported usage
  interface, which needs the local OpenCode background server. If that is
  unavailable it reads the database directly, so the widget still works
  offline.
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
- `collector.sh` — collects provider tokens/cost from OpenCode (stats API or
  database) and Go limit windows

Edits under the installed plugin directory hot-reload; force a rescan with
`omarchy-shell shell rescanPlugins` if needed.

## License

MIT — see `LICENSE`.
