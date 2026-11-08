# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.0] - 2026-11-08

First public release.

### quackd (CLI)
- Runs a DuckDB Quack server as a launchd user agent that starts only when you start it, never at login.
- Restarts after crashes and gives up after `QUACK_MAX_FAILURES` failures in a row (default 5).
- Connection logging: one line per accepted, rejected, or closed connection. Tokens are never logged.
- Crash and give-up notifications, sent through Quackd.app when it's installed and through `osascript` otherwise.
- Commands: `init <db>`, `install`, `uninstall`, `start`, `stop`, `restart`, `status [--porcelain]`, `connect`, `logs`, `run`, `version`.

### Quackd.app (menu bar)
- Shows the server's state in the menu bar, with Start, Stop, and Restart.
- First-run setup: pick a database file and the app configures and installs the service.
- Copy DuckDB Connect Command, Open Log, Edit Config, and Open Menu at Login.
- Bundles its own copy of `quackd`, so it works without the CLI installed.
