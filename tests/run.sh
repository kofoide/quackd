#!/bin/bash
# quackd test suite. Run with: make test
#
# Unit tests need nothing but macOS. Integration tests start a real Quack server
# (in the foreground, not via launchd) and need duckdb; they're skipped without it.
# Everything runs against temp directories and a test label, so your real config,
# log, and service are never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUACKD="$ROOT/bin/quackd"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/quackd-test.XXXXXX")" && pwd)"   # normalized: no // from TMPDIR
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

export QUACKD_CONFIG_DIR="$TMP/config" QUACKD_STATE_DIR="$TMP/state" QUACKD_LOG_DIR="$TMP/logs"
export QUACKD_LABEL="net.kofoid.quackd-test"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); echo "  skip  $1"; }
check() {  # check <name> <command...>: pass if the command succeeds
  local name="$1"; shift
  local out; if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi
}
contains() { [[ "$1" == *"$2"* ]]; }
q() { /bin/bash "$QUACKD" "$@"; }   # always the system bash, like launchd

# Load a one-line helper function from the script without running its main dispatch.
load_fn() { eval "$(grep -E "^$1\(\) \{.*\}$" "$QUACKD")"; }

echo "Unit tests"

check "script parses under /bin/bash 3.2" /bin/bash -n "$QUACKD"
check "version matches X.Y.Z" bash -c "[[ \"\$(/bin/bash '$QUACKD' version)\" =~ ^quackd\ [0-9]+\.[0-9]+\.[0-9]+$ ]]"

load_fn sql_quote
check "sql_quote doubles single quotes" test "$(sql_quote "it's")" = "'it''s'"
# shellcheck disable=SC2016  # literal $ intended
check "sql_quote leaves other characters alone" test "$(sql_quote 'a"b$c\d')" = "'a\"b\$c\\d'"

load_fn urlencode
check "urlencode escapes spaces, &, and UTF-8" test "$(urlencode 'a b&c ü')" = "a%20b%26c%20%C3%BC"

load_fn xml_escape
check "xml_escape escapes & < >" test "$(xml_escape 'a&b<c>')" = "a&amp;b&lt;c&gt;"

out="$(q init 2>&1)"; rc=$?
if (( rc != 0 )) && contains "$out" "usage: quackd init"; then pass "init without a path fails with usage"; else fail "init without a path fails with usage" "$out"; fi
out="$(q init "$TMP/missing.duckdb" 2>&1)"; rc=$?
if (( rc != 0 )) && contains "$out" "database not found"; then pass "init rejects a missing database"; else fail "init rejects a missing database" "$out"; fi

DB="$TMP/my db's.duckdb"
: >"$DB"   # init only checks the file exists; integration tests create a real one
check "init accepts a path with spaces and quotes" q init "$DB"
check "config file is mode 600" test "$(stat -f %Lp "$QUACKD_CONFIG_DIR/config")" = "600"
export DB QUACKD
# shellcheck disable=SC2016  # single quotes intended: expanded by the inner bash
check "config QUACK_DB round-trips the path" bash -c 'source "$QUACKD_CONFIG_DIR/config"; [[ "$QUACK_DB" == "$DB" ]]'
# shellcheck disable=SC2016
check "init refuses to overwrite an existing config" bash -c '/bin/bash "$QUACKD" init "$DB" | grep -q "already exists"' 

porcelain="$(q status --porcelain)"
missing=""
for key in version installed loaded state pid runs last_exit failures max_failures listening \
           host port log config configured config_error duckdb service_script; do
  grep -q "^$key=" <<<"$porcelain" || missing+=" $key"
done
if [[ -z "$missing" ]]; then pass "status --porcelain has every documented key"; else fail "status --porcelain has every documented key" "missing:$missing"; fi

check "install writes a valid plist" bash -c "/bin/bash '$QUACKD' install >/dev/null && plutil -lint '$QUACKD_STATE_DIR/$QUACKD_LABEL.plist'"
check "plist passes the overridden dirs to the service" bash -c \
  "[[ \"\$(plutil -extract EnvironmentVariables.QUACKD_STATE_DIR raw -o - '$QUACKD_STATE_DIR/$QUACKD_LABEL.plist')\" == '$QUACKD_STATE_DIR' ]]"

# use: switch databases by rewriting only the QUACK_DB line.
check "use with no argument prints the current database" test "$(q use)" = "$DB"
# shellcheck disable=SC2016
check "status --porcelain reports the database" bash -c '/bin/bash "$QUACKD" status --porcelain | grep -qxF "db=$DB"'
printf 'not a database, just some text\n' >"$TMP/notes.txt"
out="$(q use "$TMP/notes.txt" 2>&1)"; rc=$?
if (( rc != 0 )) && contains "$out" "not a DuckDB database"; then pass "use rejects a file that isn't a DuckDB database"; else fail "use rejects a file that isn't a DuckDB database" "$out"; fi
out="$(q use "$TMP/missing.duckdb" 2>&1)"; rc=$?
if (( rc != 0 )) && contains "$out" "database not found"; then pass "use rejects a missing database"; else fail "use rejects a missing database" "$out"; fi
# shellcheck disable=SC2089,SC2090  # the literal $ \ and " are the point of the test
DB2="$TMP/other \$db \\ \"two\".duckdb"
: >"$DB2"
token_before="$(grep '^QUACK_TOKEN=' "$QUACKD_CONFIG_DIR/config")"
out="$(q use "$DB2" 2>&1)"; rc=$?
if (( rc == 0 )) && contains "$out" "Now serving"; then pass "use switches to another database"; else fail "use switches to another database" "$out"; fi
# shellcheck disable=SC2090
export DB2
# shellcheck disable=SC2016
check "use round-trips a path with \$ \\ and quotes" bash -c 'source "$QUACKD_CONFIG_DIR/config"; [[ "$QUACK_DB" == "$DB2" ]]'
check "use keeps the rest of the config" test "$(grep '^QUACK_TOKEN=' "$QUACKD_CONFIG_DIR/config")" = "$token_before"
check "use keeps the config mode 600" test "$(stat -f %Lp "$QUACKD_CONFIG_DIR/config")" = "600"
check "use of the same database is a no-op" bash -c "/bin/bash '$QUACKD' use \"\$DB2\" | grep -q 'Already serving'"
check "use leaves no temp files behind" test -z "$(find "$QUACKD_CONFIG_DIR" -name '.config.*')"
q use "$DB" >/dev/null

# connect: the printed command must survive a round trip through the shell.
cat >"$QUACKD_CONFIG_DIR/config" <<EOF
QUACK_DB=$(printf '%q' "$DB")
QUACK_TOKEN='it'\\''s"\$x'
QUACK_LISTEN="quack:localhost:9500"
EOF
cmd="$(q connect)"
# shellcheck disable=SC2329  # invoked by the eval'd command
arg="$(duckdb() { printf '%s' "$2"; }; eval "$cmd")"
check "connect output round-trips a token with ' \" \$" test "$arg" = \
  "INSTALL quack; LOAD quack; ATTACH 'quack:localhost:9500' AS remotedb (TOKEN 'it''s\"\$x');"

echo
echo "Integration tests"

DUCKDB="$(command -v duckdb || true)"
if [[ -z "$DUCKDB" ]]; then
  skip "duckdb not installed; skipping server tests"
else
  PORT=$(( 20000 + RANDOM % 20000 ))
  TOKEN="test-token-$RANDOM"
  REAL_DB="$TMP/server.duckdb"
  "$DUCKDB" -no-agent "$REAL_DB" -c "create table t as select 42 as answer" >/dev/null
  cat >"$QUACKD_CONFIG_DIR/config" <<EOF
QUACK_DB=$(printf '%q' "$REAL_DB")
QUACK_TOKEN="$TOKEN"
QUACK_LISTEN="quack:localhost:$PORT"
QUACK_NOTIFY="false"
EOF
  LOG="$TMP/run.log"
  /bin/bash "$QUACKD" run >"$LOG" 2>&1 &
  SERVER_PID=$!
  up=""
  for _ in $(seq 1 100); do
    nc -z localhost "$PORT" 2>/dev/null && { up=1; break; }
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  if [[ -n "$up" ]]; then pass "server starts and listens on port $PORT"; else fail "server starts and listens" "$(cat "$LOG")"; fi

  answer="$("$DUCKDB" -no-agent -noheader -list -c \
    "LOAD quack; ATTACH 'quack:localhost:$PORT' AS r (TOKEN '$TOKEN'); SELECT answer FROM r.t;" 2>&1)"
  check "client with the right token can query" test "$answer" = "42"

  bad="$("$DUCKDB" -no-agent -c "LOAD quack; ATTACH 'quack:localhost:$PORT' AS r (TOKEN 'wrong-token');" 2>&1)"
  if contains "$bad" "Authentication failed"; then pass "client with a wrong token is rejected"; else fail "client with a wrong token is rejected" "$bad"; fi

  perl -e 'select(undef, undef, undef, 0.5)'
  check "log records the accepted connection" grep -q "connection accepted" "$LOG"
  check "log records the rejected connection" grep -q "connection REJECTED: .*Authentication failed" "$LOG"
  if grep -q "$TOKEN" "$LOG"; then fail "token never appears in the log"; else pass "token never appears in the log"; fi
  if pgrep -f -- "$TOKEN" >/dev/null; then fail "token never appears in ps"; else pass "token never appears in ps"; fi

  kill -TERM "$SERVER_PID"; wait "$SERVER_PID"; rc=$?; SERVER_PID=""
  check "SIGTERM stops the server with exit 0" test "$rc" = "0"
  check "log records the clean stop" grep -q "quack server stopped (received SIGTERM)" "$LOG"
  check "clean stop leaves no failure count" test ! -e "$QUACKD_STATE_DIR/$QUACKD_LABEL.failures"

  # A failed start (missing database) counts a failure and exits non-zero.
  sed -i '' "s|^QUACK_DB=.*|QUACK_DB=$(printf '%q' "$TMP/gone.duckdb" | sed 's/[|&]/\\&/g')|" "$QUACKD_CONFIG_DIR/config"
  out="$(/bin/bash "$QUACKD" run 2>&1)"; rc=$?
  if (( rc != 0 )) && contains "$out" "failure 1 of 5"; then pass "failed start counts failure 1 and exits non-zero"; else fail "failed start counts failure 1 and exits non-zero" "rc=$rc $out"; fi
  echo 4 >"$QUACKD_STATE_DIR/$QUACKD_LABEL.failures"
  out="$(/bin/bash "$QUACKD" run 2>&1)"; rc=$?
  if (( rc == 0 )) && contains "$out" "giving up after 5"; then pass "fifth failure gives up and exits 0"; else fail "fifth failure gives up and exits 0" "rc=$rc $out"; fi
fi

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
(( FAIL == 0 ))
