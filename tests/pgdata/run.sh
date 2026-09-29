#!/usr/bin/env bash
# tools/pgdata/pgdata.py against a throwaway local PostgreSQL (initdb on a free
# port under a temporary directory, removed at the end):
#   create-db, create-table (preset and column list), insert (COPY, --seed
#   repeatable), read (table, csv, json, --where, --order-by, --count, --sql in
#   a READ ONLY transaction), and the refusals: unknown column type, identifier
#   and --where injection attempts, a write through --sql, several statements.
# Requires: python3 with psycopg 3, and the PostgreSQL server binaries (initdb,
# pg_ctl) on PATH or under /usr/lib/postgresql/*/bin; skipped without them.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
PG="python3 ${ROOT}/tools/pgdata/pgdata.py"
python3 -c 'import psycopg' 2>/dev/null || { echo "SKIP tests/pgdata: psycopg 3 not installed" >&2; exit 0; }
if ! command -v initdb >/dev/null; then
  d=""; for b in /usr/lib/postgresql/*/bin; do [[ -x "$b/initdb" ]] && d="$b"; done   # any installed major version
  [[ -n "$d" && -x "$d/initdb" ]] || { echo "SKIP tests/pgdata: PostgreSQL server binaries not found" >&2; exit 0; }
  PATH="$d:$PATH"
fi
TMP="$(mktemp -d)"
export TZ=UTC   # the server and the client agree on a known time zone
# initdb refuses to run as root: use nobody when the suite runs as root
AS=(); if [[ "$(id -u)" -eq 0 ]]; then AS=(runuser -u nobody --); chown nobody "$TMP"; fi
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cleanup() { "${AS[@]}" pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT
"${AS[@]}" initdb -D "$TMP/data" -U tpg --auth=trust -E UTF8 --locale=C >/dev/null   # UTF8, as Tanzu Postgres
"${AS[@]}" pg_ctl -D "$TMP/data" -o "-p ${PORT} -k ${TMP} -c listen_addresses=127.0.0.1" -l "$TMP/log" -w start >/dev/null
export PGPASSWORD=unused
C=(--host 127.0.0.1 --port "$PORT" --user tpg --sslmode disable)

PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
pg() { RC=0; OUT="$($PG "${C[@]}" "$@" 2>&1)" || RC=$?; }

pg create-db --name shop
[[ "$RC" -eq 0 ]] && ok "create-db" || bad "create-db" "$OUT"
pg create-db --name shop --if-not-exists
[[ "$RC" -eq 0 ]] && ok "create-db --if-not-exists on an existing database" || bad "create-db again" "$OUT"
pg create-table --database shop --table customers --preset customers
[[ "$RC" -eq 0 ]] && ok "create-table --preset customers" || bad "preset" "$OUT"
pg create-table --database shop --table sales.events --columns "id:identity,at:timestamptz,amount:numeric(10,2),tag:varchar(20),ok:boolean,doc:jsonb,u:uuid"
[[ "$RC" -eq 0 ]] && ok "create-table with a schema and a column list" || bad "columns" "$OUT"

pg insert --database shop --table customers --rows 250 --seed 7
[[ "$RC" -eq 0 ]] && ok "insert 250 rows (COPY)" || bad "insert" "$OUT"
pg insert --database shop --table sales.events --rows 40 --batch-size 15
[[ "$RC" -eq 0 ]] && ok "insert into every column type, in batches" || bad "insert types" "$OUT"
pg read --database shop --table customers --count
grep -q '250' <<<"$OUT" && ok "read --count" || bad "count" "$OUT"
pg read --database shop --table sales.events --format json --limit 3 --order-by id --desc
python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); assert len(r)==3 and r[0]["id"]==40 and r[0]["id"]>r[1]["id"], r' <<<"$OUT" 2>/dev/null \
  && ok "read --format json --order-by --desc --limit" || bad "json" "$OUT"
pg read --database shop --table sales.events --format csv --where "id <= 5"
[[ "$(grep -c . <<<"$OUT")" -eq 6 ]] && head -n1 <<<"$OUT" | grep -q '^id,at,amount' \
  && python3 -c 'import csv,json,sys; r=list(csv.DictReader(sys.stdin)); assert all(x["ok"] in ("true","false") and "seq" in json.loads(x["doc"]) for x in r), r' <<<"$OUT" 2>/dev/null \
  && ok "read --format csv --where (header and 5 rows, JSON and booleans as text)" || bad "csv" "$OUT"
pg read --database shop --sql "select count(*) as n from sales.events where ok is not null"
[[ "$RC" -eq 0 ]] && grep -q '40' <<<"$OUT" && ok "read --sql runs a SELECT" || bad "sql" "$OUT"

# refusals
pg create-table --database shop --table t1 --columns "a:money"
[[ "$RC" -ne 0 ]] && grep -qi "type" <<<"$OUT" && ok "an unknown column type is refused" || bad "type" "$OUT"
pg read --database shop --table 'customers; drop table customers'
[[ "$RC" -ne 0 ]] && ok "a table name with SQL in it is refused" || bad "table injection" "$OUT"
pg read --database shop --table customers --where "1=1; drop table customers"
[[ "$RC" -ne 0 ]] && ok "a --where with SQL in it is refused" || bad "where injection" "$OUT"
pg read --database shop --sql "delete from customers"
[[ "$RC" -ne 0 ]] && grep -qi "read-only" <<<"$OUT" && ok "--sql cannot write (READ ONLY transaction)" || bad "sql write" "$OUT"
pg read --database shop --sql "commit; drop table customers; select 1 as x"
[[ "$RC" -ne 0 ]] && grep -q "one SELECT statement" <<<"$OUT" && ok "--sql refuses several statements (no escape from the read-only transaction)" || bad "sql multi" "$OUT"
pg read --database shop --table customers --count
grep -q '250' <<<"$OUT" && ok "the table is intact after the refused statements" || bad "intact" "$OUT"

echo
echo "pgdata: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
