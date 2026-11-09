# How `quackd` works

This is a guide to the inside of quackd, function by function: the [`bin/quackd`](../bin/quackd) script, the menu bar app in [`app/`](../app), the build, and the tests. For installing and using it, see the [README](../README.md).

## Repository layout

| Path | What it is |
|---|---|
| `bin/quackd` | The script: both the command-line tool and the service. |
| `app/` | The menu bar app: `QuackdMenu.swift`, the `Info.plist` template, and `build.sh`. |
| `tests/run.sh` | Test suite (`make test`). |
| `Makefile` | Install, build, test, lint, and release targets. |
| `packaging/homebrew/quackd.rb` | Template for the Homebrew formula in `kofoide/homebrew-tap`. |
| `.github/workflows/` | `ci.yml` (every push) and `release.yml` (version tags). |
| `docs/` | This file, and `releasing.md`. |

## The big picture

`quackd` is one bash script with two roles:

1. **A control tool you run yourself** (`init`, `install`, `start`, `stop`, `restart`, `status`, `connect`, `logs`, `uninstall`, `version`), either directly or through the menu bar app. These commands write config and plist files and tell macOS's service manager, **launchd**, what to do.
2. **The service itself** (`run`). launchd runs `quackd run` in the background, and that keeps the DuckDB Quack server alive.

```
you ──► quackd start ──► launchctl bootstrap ──► launchd
                                                   │ starts (and restarts on failure)
                                                   ▼
                                    /bin/bash quackd run
                                       │  config + SQL via FIFO on stdin
                                       ▼
                                    duckdb <db>  ── stdout ──► format_connection_log ──► log file
                                    (Quack server on :9494)
```

The script runs under macOS's built-in `/bin/bash`, version 3.2. Its first line is `#!/bin/bash`, so running it by hand matches what launchd runs. Some of the code is written in a slightly roundabout way to stay compatible with that old version.

## Files it uses

| Path | Variable | What it is |
|---|---|---|
| `~/.config/quackd/config` | `CONFIG_FILE` | Your settings: database, listen address, token, and so on. It's a bash file that gets `source`d, with mode 600. |
| `~/Library/Application Support/quackd/` | `STATE_DIR` | Holds the plist and the failure count. |
| `STATE_DIR/net.kofoid.quackd.plist` | `PLIST` | The launchd job definition. It's kept out of `~/Library/LaunchAgents` so it doesn't start at login. |
| `STATE_DIR/net.kofoid.quackd.failures` | `FAIL_FILE` | A single number: how many failed starts in a row. It's named after the label, so separate services keep separate counts. |
| `STATE_DIR/quackd` | — | The app's installed copy of the script. The script itself never writes it. |
| `~/Library/Logs/quackd/quackd.log` | `LOG_FILE` | Everything the service prints to stdout or stderr. |
| `~/Library/LaunchAgents/net.kofoid.quackd.plist` | `LEGACY_PLIST` | Where an early version put the plist. It's only ever deleted, never written. |

Each location can be overridden with an environment variable: `QUACKD_CONFIG_DIR`, `QUACKD_STATE_DIR`, `QUACKD_LOG_DIR`, and `QUACKD_LABEL`. The plist passes all four to the service, so `run` sees the same values as the command that installed it. The tests use them to run in temporary folders under a test label.

## Top of the script: settings and globals

- **`set -euo pipefail`** makes bash stop at the first failing command (`-e`), treat unset variables as errors (`-u`), and fail a pipeline if any part of it fails (`pipefail`).
- **`QUACKD_VERSION`** is the single source of the version number. `quackd version`, the app's `Info.plist` (through `build.sh`), `make version`, and the release workflow all read it.
- **`LABEL`** is launchd's name for the job: `net.kofoid.quackd`, or `QUACKD_LABEL` if set. Every `launchctl` command identifies the job by this name.
- **`DOMAIN`** is `gui/<your user id>`, the launchd domain for your logged-in user session. Jobs in this domain run as you, and they can show notifications.
- **`SELF`** is the absolute path of the script. The plist records it so launchd can find the script, which is why moving the script means running `install` again.
- **`STABLE_SECONDS=60`**: a run that stays up at least this long counts as a success when it's working out the failure streak.
- **`RUN_MODE`** is empty for control commands and set to `1` inside `run`. `die` checks it to decide whether to add a timestamp.

## Helper functions

### `ts`
Prints the current local time as `YYYY-MM-DD HH:MM:SS`. Every log line the script writes starts with it.

### `die <message>`
Prints an error and exits with code 1. When it runs inside `run`, the message gets a timestamp because it's going to the log. Otherwise it's a plain message for your terminal.

Inside `run`, the exit 1 goes through `on_run_exit`, which counts the failure and decides whether launchd should retry.

### `load_config`
Reads `~/.config/quackd/config` and checks it:
- the file exists
- `QUACK_DB` and `QUACK_TOKEN` are set
- the token is at least 4 characters, which quack requires
- a `duckdb` executable can be found

It also fills in defaults: `QUACK_LISTEN` falls back to `quack:localhost`, and `DUCKDB_BIN` comes from `find_duckdb`.

### `find_duckdb`
Sets `DUCKDB_BIN`, unless the config or environment already set it, to the first of:
1. `duckdb` on the `PATH`
2. `/opt/homebrew/bin/duckdb`
3. `/usr/local/bin/duckdb`

The fixed paths matter because launchd jobs and apps opened from Finder get a minimal `PATH`. If none exists, `DUCKDB_BIN` is left empty, and the app shows "DuckDB is not installed".

Because the config file is `source`d, it's executed as bash. Treat it like code, which is why it's only readable by you.

### `sql_quote <text>`
Turns text into a SQL string literal: it wraps the text in single quotes and doubles any single quotes inside it. `it's` becomes `'it''s'`.

This lets a token or address containing `'` be put safely into the `quack_serve(...)` call. It uses `sed` because bash 3.2's built-in find-and-replace leaves stray backslashes in the result.

### `urlencode <text>`
Percent-encodes text for a URL query value. It uses Perl, so non-ASCII characters are encoded byte by byte as UTF-8. `notify` uses it to build `quackd://` links.

### `xml_escape <text>`
Escapes `&`, `<`, and `>` so that paths and labels can go safely into the plist's XML.

### `check_db <path>`
Makes sure a path is usable as the database, then prints its absolute path. The file must exist. If it isn't empty, bytes 8–11 must be `DUCK`, the marker at the start of every DuckDB file. An empty file passes, because DuckDB sets one up when it opens it. Without this check, picking the wrong file would only show up when the server starts, as five crashes in a row. `init` and `use` both call it inside `$(…)`, so its `die` ends only that subshell, and the caller follows with `|| exit 1`.

### `is_loaded`
Asks launchd whether the job is currently loaded. It returns success or failure and prints nothing. "Loaded" means launchd knows about the job, whether or not the server is running right now.

### `write_plist`
Writes the launchd job file. The important keys:

| Key | Value | Why |
|---|---|---|
| `ProgramArguments` | `/bin/bash <SELF> run` | What launchd runs. |
| `EnvironmentVariables` | `PATH`, `QUACKD_CONFIG_DIR`, `QUACKD_STATE_DIR`, `QUACKD_LOG_DIR`, `QUACKD_LABEL` | launchd jobs start with a minimal `PATH`, which wouldn't include Homebrew, so the script sets one. The `QUACKD_*` values make the service use the same locations as the command that installed it. |
| `RunAtLoad` | true | Start as soon as `quackd start` loads the job. |
| `KeepAlive` | `{SuccessfulExit: false}` | Restart **only if the job exits with an error**. Exiting with 0 tells launchd not to restart it. This is what makes "give up" possible. |
| `ThrottleInterval` | 10 | Wait at least 10 seconds between restarts. |
| `StandardOutPath` / `StandardErrorPath` | the log file | Everything printed ends up in the log. |

Every value goes through `xml_escape`.

### `notify <title> <message>`
Shows a macOS notification. It's used only by `on_run_exit`. If `QUACK_NOTIFY` isn't `true`, it does nothing. It tries three methods in order:
1. **Quackd.app.** It runs `open -g "quackd://notify?title=…&message=…"`. If the app is installed, it has registered the `quackd://` URL scheme, so macOS hands it the link, launching the app if needed. The app posts the notification under its own name, and clicking it opens the log. If no app handles the scheme, `open` fails immediately, so the script moves on.
2. **terminal-notifier**, if installed. Clicking the banner opens the log in Console.
3. **`osascript`**, the built-in AppleScript runner. The title and message are passed in as arguments rather than pasted into the AppleScript code, so quotes in the message can't break it. macOS shows these notifications as coming from **Script Editor**, and they only appear if Script Editor is allowed to send notifications.

Errors are always ignored. A notification that fails to show must never stop the service from shutting down or restarting.

### `format_connection_log`
A small Perl filter that reads DuckDB's raw log output and writes one readable line per connection event. It's used when `QUACK_LOG=connections`, the default.

DuckDB's log rows are tab-separated. Field 8 is the log type and field 10 is the message. The filter:
- ignores any row whose type isn't `Quack`, and any line that isn't a full row (for example, the extra lines of a multi-line query)
- turns `CONNECTION_REQUEST` into `connection accepted`, or `connection REJECTED: <error>` if the server sent back an error
- turns `DISCONNECT_MESSAGE` into `disconnected (connection XXXXXXXX, client YYYYYYYY)`, using the first 8 characters of each ID
- drops everything else, which in practice means the `PREPARE_REQUEST` row logged for each query

`$| = 1` makes Perl write each line immediately, so the log updates in real time. Timestamps are local time at the moment a line is written, matching the rest of the log. DuckDB's own timestamps are in UTC.

## Commands

### `cmd_init` (`quackd init <db>`)
Creates the config file if it doesn't exist yet. It requires a database path, which `check_db` validates and makes absolute. The path is written with `printf %q`, so spaces and quotes survive being `source`d. It generates a random 48-character token with `openssl rand -hex 24`, sets `umask 077` and `chmod 600` so only you can read the file, and includes commented-out lines for the optional settings. If the file already exists, it leaves it alone.

### `cmd_use` (`quackd use [<db>]`)
Switches the server to another database. With no argument, it just prints the current `QUACK_DB`.

With a path:
1. **Validates** it with `check_db`. If it's already the database being served, it says so and stops.
2. **Rewrites only the `QUACK_DB=` line.** Your token, listen address, and comments stay as they are. The new line is written with `printf %q`, like `init` does. It's handed to `awk` through `ENVIRON` rather than `-v`, because `-v` would treat backslashes in the path as escape codes. If the config has no `QUACK_DB=` line, it's added at the end.
3. **Writes safely.** The result goes to a temp file in the config folder, which `mktemp` creates readable only by you. That file is then renamed over the config, so the config is never left half-written.
4. **Restarts if needed.** If the job is loaded, it calls `cmd_restart`. "Loaded" means the server was started and not stopped: running, retrying, or given up. The restart also clears the failure count. A stopped server stays stopped and serves the new database at the next `start`.

### `cmd_install` (`quackd install`)
Loads the config to catch mistakes early, writes the plist, and deletes the leftover plist from `LaunchAgents` if there is one. It does **not** start the server. If the job is already loaded, it reminds you to run `restart`, because launchd only reads the plist when the job is loaded.

### `cmd_uninstall` (`quackd uninstall`)
Unloads the job if it's loaded, which stops the server, and then deletes both plist paths. It doesn't touch your config or log.

### `cmd_start` (`quackd start`)
Clears the failure count, then:
- if the job isn't loaded, loads it with `launchctl bootstrap`, and `RunAtLoad` starts it
- if it's loaded but not running (for example, after it gave up), starts it with `launchctl kickstart`

### `cmd_stop` (`quackd stop`)
Unloads the job with `launchctl bootout`. launchd sends `run` a SIGTERM, and `run` shuts DuckDB down and logs `quack server stopped`. Unloading, rather than just stopping, makes sure launchd won't bring it back.

### `cmd_restart` (`quackd restart`)
Clears the failure count, unloads the job, and loads it again. A full reload is used, rather than `kickstart -k`, so that a plist rewritten by `install` takes effect. `bootstrap` can fail briefly while launchd is still cleaning up after the unload, so it retries up to 10 times, half a second apart.

### `cmd_status` (`quackd status`)
Shows:
- launchd's view of the job: `state`, `pid`, `runs` (how many times launchd has started it), and `last exit code`
- `consecutive failures: N`, but only when the server isn't running. The count isn't cleared while a healthy run is in progress, so showing it then would be misleading.
- `listening: yes/no`, from trying to connect to the host and port in `QUACK_LISTEN` with `nc`. The default port is 9494.

It loads the config in a subshell first, so a missing or broken config just skips the "listening" line instead of quitting `status` with an error.

#### `status --porcelain` (`status_porcelain`)
The same information in a form that's easy for programs to read: one `key=value` per line, with no quotes. The keys are:
- **Version:** `version`.
- **launchd:** `installed`, `loaded`, `state`, `pid`, `runs`, `last_exit`.
- **Failures:** `failures`, `max_failures`.
- **Server:** `listening`, `host`, `port`.
- **Files:** `log` and `config` (paths).
- **Setup checks:**
  - `configured`: `yes` if `load_config` succeeds.
  - `config_error`: its error message otherwise.
  - `duckdb`: the DuckDB path that was found, empty if none.
  - `service_script`: the script path recorded in the installed plist.
- **Database:** `db`, the `QUACK_DB` path. It's empty if the config doesn't load.

To get `config_error`, it runs `load_config` in a subshell and captures what `die` prints.

Unlike the normal output, `failures` is always included, and the program reading it decides what it means. The menu bar app gets all of its state this way. Treat these keys as a contract: adding a key is fine, but renaming or removing one breaks the app. A test checks that every key is present.

### `listen_host_port`
Splits `QUACK_LISTEN` (`quack:host[:port]`) into `LISTEN_HOST` and `LISTEN_PORT`. The port defaults to 9494. It's used by `status`, `status --porcelain`, and `connect`.

### `cmd_connect` (`quackd connect`)
Prints a ready-to-paste command: `duckdb -cmd "INSTALL quack; LOAD quack; ATTACH 'quack:host:port' AS remotedb (TOKEN '…');"`. The address and token are quoted for SQL with `sql_quote`.

If the result contains characters that are special inside double quotes (`"`, `$`, `` ` ``, `\`, or `!`), it uses `printf %q` to escape the whole argument for the shell instead. That looks messier, but it pastes correctly.

### `version`
`quackd version` (or `--version`, or `-v`) prints `quackd X.Y.Z`. It's handled directly in the dispatch `case`.

### `cmd_logs` (`quackd logs`)
Shows the last 50 lines of the log and keeps following it, like `tail -f`.

### `cmd_run` (`quackd run`)
The service itself. launchd runs this, and you can also run it in a terminal to debug. In order:

1. **Set up failure handling.** It sets `RUN_MODE`, records the start time, and registers `on_run_exit` to run however the script exits, whether through `die`, a failing command, or the normal end.
2. **Check the config** and that the database file exists.
3. **Build the startup SQL.** That's `call quack_serve('<listen>', token='<token>'[, extra args]);`, with values quoted by `sql_quote`.
4. **Create a FIFO that never reaches end-of-file.** This is the core trick. `quack_serve()` returns right away and serves from a background thread, and the `duckdb` command-line tool exits as soon as its input runs out. The script creates a named pipe, opens it for reading *and* writing on file descriptor 3, and deletes the name. Because the same descriptor keeps the pipe open for writing, DuckDB never sees the input end and simply waits forever.
5. **Choose the logging mode** from `QUACK_LOG`. For `connections` and `all`, it adds `CALL enable_logging(['Quack'], level='debug', storage='stdout');`.
6. **Write the startup commands into the FIFO:**
   - `.bail on` makes DuckDB exit if a command fails, so a failed `quack_serve` turns into a restart instead of a process that's alive but not serving.
   - `.output /dev/null` … `.output` hides the output of those commands. `quack_serve` prints the token in its result table, and this keeps it out of the log.

   The SQL goes in through the pipe rather than as a command-line argument, so the token doesn't appear in `ps`.
7. **Start DuckDB as a child process**, with the FIFO as its input:
   - In `connections` mode, DuckDB's output goes through a second, temporary FIFO into `format_connection_log`, which runs as a separate background process. The script keeps both process IDs.
   - In `all` or `off` mode, DuckDB's output goes straight to the log.

   Then it closes its own copy of descriptor 3. DuckDB holds its own copy, opened for reading and writing, so it still never sees the input end.
8. **Pass shutdown signals on.** On TERM, INT, or HUP, it records which signal arrived and sends SIGTERM to DuckDB.
9. **Wait for DuckDB to exit.** A signal interrupts bash's `wait`, so it loops until the process is really gone and keeps its exit code. It then waits for the log filter, so the filter's last lines are written before the final message.
10. **Log how it ended:**
    - It was stopped by a signal: logs `quack server stopped (received SIGTERM)` and exits 0.
    - DuckDB exited on its own: logs `quack server exited unexpectedly (exit code N)` and exits with that code. If DuckDB somehow exited with 0, it exits 1, so an unexpected exit is never treated as a clean stop.

### `on_run_exit <exit code>`
Runs whenever `cmd_run` exits. It decides whether launchd retries. It first unregisters itself so it can't run twice.

- **Exit code 0** (clean stop): deletes the failure-count file and exits 0. launchd doesn't restart it.
- **Any other exit code** (failure):
  1. Reads the current count, but only if this run lasted less than `STABLE_SECONDS`. A run that stayed up longer starts a fresh count, so an occasional crash after hours of uptime is failure 1 again.
  2. Adds one and saves it.
  3. If `QUACK_MAX_FAILURES` is greater than 0 and the count has reached it, it logs `giving up…`, sends a "gave up" notification, and **exits 0**. With `SuccessfulExit: false`, that tells launchd to stop retrying.
  4. Otherwise, it sends a notification only if this is failure 1, logs `failure N of MAX`, and exits with the original error code. launchd restarts it after about 10 seconds.

An invalid `QUACK_MAX_FAILURES` falls back to 5, and `0` means retry forever.

## The menu bar app (`app/`)

| File | Purpose |
|---|---|
| `QuackdMenu.swift` | The whole app, about 450 lines of SwiftUI and AppKit. |
| `Info.plist` | App bundle settings. `build.sh` fills in the `@…@` placeholders. It also registers the `quackd://` URL scheme. |
| `build.sh` | Compiles with `swiftc`, assembles `Quackd.app`, bundles the script, and signs it. |

**`build.sh [output-dir]`**, usually run as `make app`:
1. **Version:** reads `QUACKD_VERSION` from `bin/quackd`, so the app and script versions always match.
2. **Compile:** compiles `QuackdMenu.swift` twice, for `arm64` and `x86_64`, targeting macOS 13, the minimum for `MenuBarExtra` and `SMAppService`. Then `lipo` joins the two into one universal binary that runs on Apple Silicon and Intel. The Intel link warns about `libswiftCompatibilityPacks.a`, which is harmless, because the app doesn't use Swift parameter packs.
3. **Info.plist:** fills in the `Info.plist` placeholders and checks the result with `plutil`.
4. **Bundle the script:** copies `bin/quackd` into `Contents/Resources/quackd`.
5. **Sign:** ad-hoc signs it with `codesign --sign -`, which is enough to run on the Mac that built it.

`LSUIElement` in the plist makes it a menu-bar-only app, with no Dock icon or app menu.

**Inside `QuackdMenu.swift`:**

- **`ServiceStatus`** holds one snapshot of `status --porcelain`, and `parse` reads it. The computed `phase` is checked in this order:
  1. the status command failed → `unknown`
  2. launchd says running → `running` if the port answers, `starting` if not
  3. no DuckDB found → `noDuckDB`
  4. config missing or invalid → `notConfigured`
  5. no plist → `notInstalled`
  6. failure count at the limit → `gaveUp`
  7. launchd is waiting to retry (`spawn scheduled`) → `retrying`
  8. anything else → `stopped`

  "Running" is checked early, so a server that's already up is shown as up, even if, say, DuckDB has since been uninstalled.
- **`Shell`** finds and runs the script:
  - **Script location:** `scriptPath` is the stable copy at `~/Library/Application Support/quackd/quackd`.
  - **`installBundledScript()`** copies the bundled script there if it's missing or different, and makes it executable. It runs at launch, so the stable copy always matches the app's version. The launchd service points at this copy, not at the app bundle, so moving or replacing the app doesn't break the service.
  - **Running commands:** `quackd(args)` runs `/bin/bash <scriptPath> <args>`. `run` runs a program on a background thread and returns its exit code plus its combined output. It adds Homebrew to `PATH`.
- **`AppDelegate`**:
  - asks for notification permission at launch, so macOS shows the standard prompt under "Quackd"
  - handles `quackd://notify?title=…&message=…` in `application(_:open:)` by posting the notification with `UNUserNotificationCenter`
  - shows banners even while the app is active
  - opens the log in Console when a notification is clicked, using `logPath`, which the `Controller` keeps current
- **`Controller`** holds the app's state and actions:
  - **Refreshing:** `refresh()` runs `status --porcelain` at launch and every 5 seconds.
  - **Repairing the service:** `repairServiceIfNeeded` runs `quackd install` once if the installed plist points at a script that no longer exists. That happens when the service was installed from a clone that was later moved or deleted. Running `install` repoints the service at the app's copy. If the recorded script still exists, for example a Homebrew or `make install` copy, the app leaves it alone.
  - **`perform(args)`** runs `start`, `stop`, `restart`, or `install`. It shows circular arrows while it runs and an alert if the command fails, then refreshes immediately and again after 1 and 3 seconds.
  - **`setUp()`** handles first-run setup. An open panel picks the database, then the app runs `quackd init <db>` and `quackd install`.
  - **Switching databases:**
    - **Picking a file:** `chooseDatabase()` opens the same file picker, starting in the current database's folder.
    - **Switching:** `switchDatabase(to:)` runs `quackd use <db>`. If the server is loaded, it first asks for confirmation, because the restart disconnects clients.
    - **Recents:** `recentDatabases` holds up to 8 databases, newest first, in `UserDefaults`. Every database the app sees in `status` is added, including ones switched from the CLI. Files that no longer exist are hidden, and `displayName` adds the folder when two recents share a file name.
  - **Menu actions:** `copyConnectCommand()`, `openLog()`, `openConfig()`, `openDuckDBInstallPage()`, and `openProjectPage()`.
  - **Login item:** `setOpenAtLogin` registers or removes the *app* as a login item with `SMAppService.mainApp`. It never affects the server.
  - **Display:** `iconName`, `statusLine`, and `detailLine` map the phase to an SF Symbol and the text at the top of the menu. `detailLine` explains a missing DuckDB or a broken config.
- **`MenuContent`** is the menu. The action section depends on the phase:
  - **No DuckDB:** "How to Install DuckDB…"
  - **Not configured:** "Set Up…"
  - **Not installed:** "Install Service"
  - **Otherwise:** Start, Stop, and Restart, each disabled when it doesn't apply.

  Once configured, a **Database: *name*** submenu sits under the status line. It lists the recent databases, with the current one checked, followed by Choose Database… and Clear Recent Databases.

  The menu ends with the version, which links to the GitHub page.
- **`QuackdMenuApp`** is the entry point: a `MenuBarExtra` with `.menu` style, and `AppDelegate` attached through `@NSApplicationDelegateAdaptor`.

The app never touches launchd, the config, or DuckDB directly. Everything goes through the script, so it can't drift out of sync with the command line.

## Build, test, and release

### `Makefile`
| Target | What it does |
|---|---|
| `install` / `uninstall` | Copies `bin/quackd` to `$(BINDIR)` (default `~/.local/bin`), and warns if that isn't on your `PATH`. `uninstall` removes it. |
| `app` | `app/build.sh build`. |
| `install-app` / `uninstall-app` | Quits a running copy with `pkill -x QuackdMenu`, then replaces or removes `~/Applications/Quackd.app`. `install-app` opens the new copy. |
| `test` | Runs `tests/run.sh`. |
| `lint` | Runs `shellcheck` on all shell scripts. |
| `dist` | Builds `build/dist/` with `quackd`, `Quackd-X.Y.Z.zip` (made with `ditto`, which keeps the bundle's signature intact), and `SHA256SUMS`. |
| `version` | Prints `QUACKD_VERSION`. |

### `tests/run.sh`
Everything runs against a temporary folder and the label `net.kofoid.quackd-test`, through the `QUACKD_*` overrides, so it never touches your real setup. It never uses launchd, because GitHub's macOS runners have no logged-in user session to install a service into.
- **Unit tests** check:
  - the script parses under `/bin/bash` 3.2
  - the version format
  - `sql_quote`, `urlencode`, and `xml_escape`, which are loaded straight from the script with `grep`
  - `init`: errors, a path with spaces and quotes, file mode 600, refusing to overwrite
  - every porcelain key is present
  - `use`: printing the current database, rejecting missing and non-DuckDB files, a path with `$`, `\`, and `"`, leaving the token and file mode alone, no-op on the same database, no leftover temp files
  - `install` writes a valid plist
  - `connect` output round-trips through the shell
- **Integration tests** run only if `duckdb` is installed. They start `quackd run` on a random port and check that:
  - a client with the right token can query
  - a client with a wrong token is rejected
  - both connections are logged
  - the token appears in neither the log nor `ps`
  - SIGTERM exits 0 and logs the stop
  - a missing database counts failure 1, and the 5th failure gives up with exit 0

### CI and releases
- **`ci.yml`:** on every push and pull request, it installs `shellcheck` and `duckdb` with Homebrew, then runs `make lint`, `make test`, and `make app`.
- **`release.yml`:** on a `v*` tag, it checks that the tag matches `QUACKD_VERSION`, runs lint and tests, runs `make dist`, and publishes a GitHub Release with the artifacts.

See [releasing.md](releasing.md) for the full checklist.

## Main dispatch
The `case` statement at the bottom calls the `cmd_*` function for the command you typed. An unknown command, or none at all, prints the usage text. That text comes from the comment block at the top of the script, using `awk`, so it can't get out of sync with the comments.

## Exit codes and what launchd does

| Situation | `run` exits with | launchd |
|---|---|---|
| `quackd stop` / `restart` / `uninstall` (SIGTERM) | 0 | Job unloaded, nothing restarts. |
| DuckDB crashes or can't start, below the failure limit | DuckDB's code (or 1) | Restarts in about 10 seconds. |
| Config or database error before DuckDB starts, below the limit | 1 | Restarts in about 10 seconds. |
| Failure limit reached | 0 | Stays loaded but stopped; `quackd start` brings it back. |
