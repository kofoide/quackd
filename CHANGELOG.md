# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org).

## [1.6.0] - 2026-11-09

### quackd (CLI)
- New `quackd clients` lists the connected clients. `status` shows the count, and `status --porcelain` has a new `connections` key. The running server takes a snapshot of its own connections every 2 seconds, so checking doesn't add connections to the log.
- `quackd connect` names the attached database after the served file (`sales.duckdb` → `sales`) instead of `remotedb`. Names that aren't valid identifiers are adjusted, for example `My Data.duckdb` → `My_Data` and `select.duckdb` → `select_db`.
- New `quackd activity [N]` shows recent connections, rejections, starts, and stops from the log.
- The log now rotates when it reaches `QUACK_LOG_MAX_MB` (default 10), keeping `QUACK_LOG_KEEP` old copies (default 3). `quackd logs` keeps following across rotations.

### Quackd.app (menu bar)
- Shows how many clients are connected. Stop, Restart, and switching databases ask first when clients would be disconnected, and no longer ask when nobody is connected.
- New **Recent Activity** submenu.

## [1.5.0] - 2026-11-09

### quackd (CLI)
- New `quackd use <db>` switches the database being served. It changes only the `QUACK_DB` line in the config and restarts the server if it's running. `quackd use` with no argument prints the current database.
- `init` and `use` reject files that aren't DuckDB databases, instead of failing later as a crash loop.
- `status` shows the database, and `status --porcelain` has a new `db` key.

### Quackd.app (menu bar)
- New **Database** submenu: recent databases and **Choose Database…**. It confirms before restarting a running server.

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
