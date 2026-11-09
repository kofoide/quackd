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
  "INSTALL quack; LOAD quack; ATTACH 'quack:localhost:9500' AS my_db_s (TOKEN 'it''s\"\$x');"

# connect names the attached database after the file (connect_alias).
alias_for() {  # alias_for <file name>: the AS name connect prints for that database
  printf 'QUACK_DB=%q\nQUACK_TOKEN=abcd1234\n' "$TMP/$1" >"$QUACKD_CONFIG_DIR/config"
  q connect | sed -n 's/.* AS \([^ ]*\) (TOKEN.*/\1/p'
}
check "connect names the database after the file" test "$(alias_for sales.duckdb)" = "sales"
check "connect keeps only the last extension off" test "$(alias_for 'q4.backup.duckdb')" = "q4_backup"
check "connect turns spaces and dashes into _" test "$(alias_for 'My Data-2026.duckdb')" = "My_Data_2026"
check "connect puts _ before a leading digit" test "$(alias_for 2026.duckdb)" = "_2026"
if command -v duckdb >/dev/null; then
  check "connect adds _db to a reserved word" test "$(alias_for select.duckdb)" = "select_db"
fi
check "connect adds _db to a built-in database name" test "$(alias_for memory.duckdb)" = "memory_db"
check "connect falls back to remotedb" test "$(alias_for .duckdb)" = "remotedb"

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
QUACK_LOG_MAX_MB=1
QUACK_LOG_KEEP=2
EOF
  # Write to the real log path in append mode, like launchd, so activity and log
  # rotation see it. Start with an oversized log and an older rotation to shift.
  LOG="$QUACKD_LOG_DIR/quackd.log"
  mkdir -p "$QUACKD_LOG_DIR"
  echo "older rotation" >"$LOG.1"
  head -c 1100000 /dev/zero | tr '\0' 'x' >"$LOG"
  /bin/bash "$QUACKD" run >>"$LOG" 2>&1 &
  SERVER_PID=$!
  up=""
  for _ in $(seq 1 100); do
    nc -z localhost "$PORT" 2>/dev/null && { up=1; break; }
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  if [[ -n "$up" ]]; then pass "server starts and listens on port $PORT"; else fail "server starts and listens" "$(tail -c 2000 "$LOG")"; fi

  check "oversized log is rotated at startup" test "$(stat -f %z "$LOG.1")" -ge 1100000
  check "older rotation shifts to .2" grep -qx "older rotation" "$LOG.2"
  check "rotated log starts fresh" bash -c "head -1 '$LOG' | grep -q 'log rotated at 1 MB' && (( \$(stat -f %z '$LOG') < 10000 ))"

  perl -e 'select(undef, undef, undef, 2.5)'   # first connection snapshot
  check "clients reports no connections at first" bash -c "/bin/bash '$QUACKD' clients | grep -q 'No clients connected'"

  answer="$("$DUCKDB" -no-agent -noheader -list -c \
    "LOAD quack; ATTACH 'quack:localhost:$PORT' AS r (TOKEN '$TOKEN'); SELECT answer FROM r.t;" 2>&1)"
  check "client with the right token can query" test "$answer" = "42"

  bad="$("$DUCKDB" -no-agent -c "LOAD quack; ATTACH 'quack:localhost:$PORT' AS r (TOKEN 'wrong-token');" 2>&1)"
  if contains "$bad" "Authentication failed"; then pass "client with a wrong token is rejected"; else fail "client with a wrong token is rejected" "$bad"; fi

  # A client that stays connected for a few seconds shows up in clients and status.
  ( (echo "LOAD quack; ATTACH 'quack:localhost:$PORT' AS r (TOKEN '$TOKEN'); SELECT 1;"; sleep 6) \
      | "$DUCKDB" -no-agent >/dev/null 2>&1 ) 2>/dev/null &
  HOLDER=$!
  perl -e 'select(undef, undef, undef, 3.5)'
  out="$(q clients)"
  if contains "$out" "1 connection:"; then pass "clients lists a connected client"; else fail "clients lists a connected client" "$out"; fi
  check "status --porcelain counts the connection" bash -c "/bin/bash '$QUACKD' status --porcelain | grep -qx 'connections=1'"
  { pkill -P "$HOLDER"; wait "$HOLDER"; } 2>/dev/null   # disconnect it (only this test's processes)

  check "log records the accepted connection" grep -q "connection accepted" "$LOG"
  check "log records the rejected connection" grep -q "connection REJECTED: .*Authentication failed" "$LOG"
  if grep -q "$TOKEN" "$LOG"; then fail "token never appears in the log"; else pass "token never appears in the log"; fi
  if pgrep -f -- "$TOKEN" >/dev/null; then fail "token never appears in ps"; else pass "token never appears in ps"; fi

  kill -TERM "$SERVER_PID"; wait "$SERVER_PID"; rc=$?; SERVER_PID=""
  check "SIGTERM stops the server with exit 0" test "$rc" = "0"
  check "log records the clean stop" grep -q "quack server stopped (received SIGTERM)" "$LOG"
  check "clean stop leaves no failure count" test ! -e "$QUACKD_STATE_DIR/$QUACKD_LABEL.failures"
  check "clean stop removes the clients snapshot" test ! -e "$QUACKD_STATE_DIR/$QUACKD_LABEL.clients"
  check "clients says the server isn't running after a stop" bash -c "/bin/bash '$QUACKD' clients | grep -q \"isn't running\""

  activity="$(q activity 20)"
  if contains "$activity" "connection accepted" && contains "$activity" "connection REJECTED" \
     && [[ "$(tail -1 <<<"$activity")" == *"quack server stopped (received SIGTERM)" ]]; then
    pass "activity shows connections, rejections, and the stop"
  else
    fail "activity shows connections, rejections, and the stop" "$activity"
  fi
  if grep -q 'xxxx' <<<"$activity"; then fail "activity skips non-event lines"; else pass "activity skips non-event lines"; fi
  check "activity N limits the output" test "$(q activity 2 | wc -l | tr -d ' ')" = "2"
  out="$(q activity abc 2>&1)"; rc=$?
  if (( rc != 0 )) && contains "$out" "usage: quackd activity"; then pass "activity rejects a non-number"; else fail "activity rejects a non-number" "$out"; fi

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
