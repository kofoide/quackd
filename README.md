# quackd

Run a [DuckDB](https://duckdb.org) **Quack** server on your Mac as a background service, controlled from the command line or the menu bar.

Quack is DuckDB's extension for serving a database to other DuckDB clients over the network. On its own, starting a server means keeping a terminal open:

```sh
duckdb my.duckdb -cmd "call quack_serve('quack:localhost', token='…');"
```

quackd turns that into a proper macOS service:

- **Runs in the background** under launchd, with no terminal window.
- **Starts only when you ask.** It never auto-starts at login or after a reboot.
- **Recovers from crashes**, and gives up with a notification if something is persistently wrong, such as a missing database or another process holding the lock.
- **Logs every connection**, accepted or rejected, without ever writing your token to the log or exposing it in `ps`.
- **Comes with a menu bar app**, so you can see at a glance whether the server is up, start or stop it, and copy a ready-to-paste connect command.

## Requirements

- macOS 13 (Ventura) or later, on Apple Silicon or Intel.
- **DuckDB with the `quack` extension**, which you install yourself, for example with `brew install duckdb`. quackd uses whichever `duckdb` it finds: the one on your `PATH`, then `/opt/homebrew/bin`, then `/usr/local/bin`, or set `DUCKDB_BIN` in the config. It's tested with DuckDB v2.0.0.
- **To build from source:** the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.

## Install

### From source (recommended)

```sh
git clone https://github.com/kofoide/quackd.git
cd quackd
make install        # the quackd CLI → ~/.local/bin/quackd
make install-app    # the menu bar app → ~/Applications/Quackd.app (optional)
```

To install the CLI somewhere else, use `make install PREFIX=/usr/local`. Apps you build yourself open without any macOS security prompt.

### CLI with Homebrew

```sh
brew install kofoide/tap/quackd
```

### Prebuilt app from Releases

Download `Quackd-X.Y.Z.zip` from [Releases](https://github.com/kofoide/quackd/releases), unzip it, and move **Quackd.app** to Applications. The app isn't notarized by Apple, so macOS blocks it the first time you open it. Go to **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once.

## Quick start

### With the menu bar app

1. Open **Quackd**. A bird appears in the menu bar.
2. Choose **Set Up…** and pick your `.duckdb` file. quackd writes a config with a random token and installs the service.
3. Choose **Start**. The bird fills in once the server is accepting connections.
4. Choose **Copy DuckDB Connect Command**, and paste it into a terminal on the same Mac.

### With the CLI

```sh
quackd init ~/data/my.duckdb   # config with a random token: ~/.config/quackd/config
quackd install                 # register the service (doesn't start it)
quackd start
quackd status
quackd connect                 # prints a ready-to-run duckdb command
```

## Connecting

`quackd connect`, or the menu's **Copy DuckDB Connect Command**, prints something like:

```sh
duckdb -cmd "INSTALL quack; LOAD quack; ATTACH 'quack:localhost:9494' AS remotedb (TOKEN '…');"
```

Then query `remotedb` like a local database. To use DuckDB's web UI, add `CALL start_ui();` at the end of the `-cmd` string. Keep that terminal open, because the UI runs inside that `duckdb` process.

## Commands

| Command | What it does |
|---|---|
| `quackd init <db>` | Create `~/.config/quackd/config` for `<db>` with a random token. It won't overwrite an existing config. |
| `quackd install` | Register the launchd service. Doesn't start it. Run it again after upgrading. |
| `quackd start` / `stop` / `restart` | Control the server. `restart` also applies a reinstalled service file. |
| `quackd status` | launchd state, failure count, and whether the port is accepting connections. `--porcelain` gives stable `key=value` output for scripts. |
| `quackd connect` | Print a `duckdb` command that attaches to the server. |
| `quackd logs` | Follow the log. |
| `quackd uninstall` | Stop the server and remove the service. Keeps your config and log. |
| `quackd run` | Run the server in the foreground. This is what launchd runs, and it's useful for debugging. |
| `quackd version` | Print the version. |

## The menu bar app

| Icon | Meaning |
|---|---|
| filled bird | Running and accepting connections |
| outline bird | Stopped, or not set up yet |
| circular arrows | Starting, retrying after a failure, or running a command |
| warning triangle | Gave up after repeated failures, DuckDB isn't installed, or status is unavailable |

The menu offers Start, Stop, and Restart, plus:
- **Copy DuckDB Connect Command**
- **Open Log**, which opens the log in Console
- **Edit Config**
- **Open Menu at Login**, which opens *the menu app* at login. The server still only starts when you click Start.

Quitting the app leaves the server running.

The app contains its own copy of `quackd` and runs it for every action, so the menu and the CLI always behave the same way. You don't need the CLI installed to use the app.

## Configuration

`~/.config/quackd/config` is a bash file. It holds your token, so it's readable only by you. After editing it, run `quackd restart`.

| Variable | Default | Notes |
|---|---|---|
| `QUACK_DB` | — | Path to the `.duckdb` file. |
| `QUACK_LISTEN` | `quack:localhost` | Address to listen on. The default port is 9494, e.g. `quack:localhost:9500`. |
| `QUACK_TOKEN` | random | Clients must send this to connect. At least 4 characters. |
| `QUACK_LOG` | `connections` | `connections`: one line per connect or disconnect. `all`: raw DuckDB log rows, including each query's SQL. `off`: no client logging. |
| `QUACK_MAX_FAILURES` | `5` | Stop retrying after this many failed starts in a row. `0` retries forever. |
| `QUACK_NOTIFY` | `true` | Notify on the first crash and when it gives up. |
| `DUCKDB_BIN` | auto-detected | Path to `duckdb`. |
| `QUACK_EXTRA_ARGS` | — | Extra named arguments for `quack_serve()`, e.g. `allow_other_hostname=true`. |

## Logs, crashes, and notifications

The log is at `~/Library/Logs/quackd/quackd.log`. Run `quackd logs` to follow it.

```
2026-11-07 11:21:24 starting quack server: db=/Users/me/data/my.duckdb listen=quack:localhost
2026-11-07 11:21:24 connection accepted
2026-11-07 11:21:24 disconnected (connection 82A19F81, client 04771310)
2026-11-07 11:21:30 connection REJECTED: Invalid Input Error: Authentication failed
2026-11-07 11:24:47 quack server stopped (received SIGTERM)
```

If the server dies or can't start, the log says why, and launchd retries about every 10 seconds:

```
2026-11-07 11:32:47 starting quack server: db=… listen=quack:localhost
IO Error: Could not set lock on file "…": Conflicting lock is held in … (PID 20294)
2026-11-07 11:32:47 quack server exited unexpectedly (exit code 1)
2026-11-07 11:32:47 quackd: failure 1 of 5; launchd will retry in about 10 seconds
…
2026-11-07 11:33:27 quackd: giving up after 5 consecutive failures. Fix the problem above, then run: quackd start
```

After `QUACK_MAX_FAILURES` failures in a row, it stops retrying until you run `quackd start` or click Start. A run that stays up for at least 60 seconds starts a fresh count.

You get **one notification on the first failure and one if it gives up**, not one per retry. If Quackd.app is installed, notifications come from it, and clicking one opens the log. Without the app, quackd uses `terminal-notifier` if you have it, and otherwise macOS's built-in `osascript`. macOS lists `osascript` notifications under **Script Editor** in System Settings → Notifications, and they only appear once Script Editor is allowed there. If you see nothing, open Script Editor, run `display notification "test"` once, and click Allow.

The log doesn't rotate. With `QUACK_LOG=all` it grows quickly.

## Security notes

- **Keep it on `localhost`** unless you mean to share it. The token is the only protection. On localhost, quack serves plain HTTP. Before exposing the server on a network, set up TLS with `quack_serve`'s `ssl_cert_file` / `ssl_key_file` options, which you can pass with `QUACK_EXTRA_ARGS`.
- **Use the generated token.** `init` creates a random 48-character token. Anything that can read your config, or that you give the connect command to, can use your database.
- **The token stays out of `ps` and the log.** The startup SQL goes in through a pipe, and its output is discarded.
- **Client addresses aren't logged.** Quack doesn't report a client's IP address. The `client` value in the log is an anonymous, per-process ID.

## Things to know

- **Database lock:** while the server runs, it holds DuckDB's write lock on the database, so other `duckdb` processes can't open the file read-write. Go through the server, or `quackd stop` first.
- **No auto-start:** the service file lives in `~/Library/Application Support/quackd/`, not `~/Library/LaunchAgents`, so launchd never loads it at login. After a reboot, start it again.
- **Upgrading:** run `quackd install`, then `quackd restart`. The app does this by itself if the script the service uses has disappeared.

## Uninstall

```sh
quackd uninstall                  # stop and remove the service
make uninstall uninstall-app      # remove the CLI and the app (from the clone)
rm -rf ~/.config/quackd ~/Library/Logs/quackd "$HOME/Library/Application Support/quackd"
```

## Development

```sh
make test       # unit + integration tests (integration tests need duckdb)
make lint       # shellcheck
make app        # build build/Quackd.app
make dist       # release artifacts in build/dist/
```

- **Internals:** [docs/quackd-internals.md](docs/quackd-internals.md) walks through the script and the app function by function.
- **Releasing:** [docs/releasing.md](docs/releasing.md) covers versioning, tagging, the Homebrew tap, and optional notarization.
- **CI:** GitHub Actions runs lint, tests, and the app build on every push.

## License

[MIT](LICENSE) © Eric Kofoid
