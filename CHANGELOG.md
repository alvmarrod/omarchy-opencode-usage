# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-11-01

### Added

- Dashed "peak usage" line and right-aligned label in the 7-day chart.

### Changed

- Expanded the marketplace description.
- Added this changelog.
- Refreshed the marketplace preview screenshot.

## [2.1.1] - 2026-11-01

### Security

- Keep provider, model, daily, and summary usage payloads out of jq process
  arguments; jq reads them on stdin instead.

## [2.1.0] - 2026-11-01

### Fixed

- Failed requests with zero tokens or cost no longer create provider/model
  usage rows.

### Changed

- The weekly pace indicator now sits beside the WEEK label and is tinted
  yellow.
- Refreshed the marketplace preview screenshot.

## [2.0.0] - 2026-10-29

### Added

- OpenCode v2 usage support from per-message `session_message` data.
- OAuth/device and API-key credential support from the `credential` table,
  with `auth.json` as a fallback.

### Changed

- Moved to the standalone `alvmarrod/omarchy-opencode-usage` repository and
  `io.github.alvmarrod.opencode-usage` plugin ID.
- Calendar-aligned 7/30-day usage windows.
- Hardened collector runtime boundary and weekly budget indicator.

## [1.1.0] - 2026-09-12

### Changed

- Inherited upstream release: rebranded as opencode-tracker under thespd,
  including bar button/wordmark and provider-label fixes.
