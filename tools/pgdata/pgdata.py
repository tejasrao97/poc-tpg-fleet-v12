#!/usr/bin/env python3
"""pgdata: create databases and tables, insert random rows and read them back
on a Tanzu Postgres instance (design decision D68).

Two ways to run it:
  flags        pgdata.py [connection flags] COMMAND [command flags]
               The password comes from --password, else PGPASSWORD, else a
               hidden prompt (--password is visible in the process list).
  prompts      pgdata.py            (no command, or --interactive)
               Asks for the connection and then the action, step by step.

Connection (given by hand; nothing is read from the cluster):
  --host HOST  --port 5432  --user USER  --dbname postgres
  --sslmode prefer (disable | allow | prefer | require | verify-ca | verify-full)
  --sslrootcert FILE   CA certificate for verify-ca / verify-full
Reach the instance through its Service address (exposure internalLoadBalancer
or loadBalancer), or run "kubectl -n pg-<instance> port-forward svc/<instance>
5432" first and use --host 127.0.0.1. The credentials are in the Secret
pg-<instance>/<instance>-db-secret (keys username and password).

Commands:
  create-db     --name NAME [--owner ROLE] [--if-not-exists]
  create-table  --database DB --table [SCHEMA.]TABLE   (a missing SCHEMA is created)
                (--preset customers|orders|sales_events | --columns "name:type,...")
                [--primary-key COLUMN] [--if-not-exists]
                Column types: smallint integer bigint serial bigserial real
                "double precision" boolean text date timestamp timestamptz uuid json
                jsonb, numeric or numeric(P,S), varchar(N), char(N); an identity
                column is "id:identity".
  insert        --database DB --table [SCHEMA.]TABLE [--rows 100] [--batch-size 1000] [--seed N]
                Values are generated from the column types (information_schema);
                identity, serial and generated columns are left to Postgres. COPY is used.
  read          --database DB --table [SCHEMA.]TABLE [--limit 20] [--where "COLUMN OP VALUE"]
                [--order-by COLUMN [--desc]] [--count] [--format table|csv|json]
                or --database DB --sql "SELECT ..." (one statement, READ ONLY)
                --where operators: = != < <= > >= like ilike "is null" "is not null".

Identifiers are checked and quoted (psycopg.sql.Identifier); values are passed
as query parameters. Column types come from a fixed list. --sql runs exactly one
statement (sent as a prepared statement, so "commit; ..." is refused) inside a
READ ONLY transaction, on a session whose transactions default to read-only.

Requires Python 3.9+ and psycopg 3: pip install "psycopg[binary]".
"""
import argparse
import csv
import datetime as dt
import decimal
import getpass
import json
import os
import random
import re
import string
import sys
import uuid

try:
    import psycopg
    from psycopg import sql
    from psycopg.types.json import Jsonb
except ImportError:  # pragma: no cover - message for the operator
    sys.exit('pgdata needs psycopg 3: pip install "psycopg[binary]"')

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]{0,62}$")
TYPE_PATTERNS = [
    re.compile(r"^(smallint|integer|int|bigint|serial|bigserial|real|double precision|boolean|bool|text|date"
               r"|timestamp|timestamptz|timestamp with time zone|timestamp without time zone|uuid|json|jsonb)$"),
    re.compile(r"^numeric(\(\s*\d{1,3}\s*(,\s*\d{1,3}\s*)?\))?$"),
    re.compile(r"^(varchar|character varying|char|character)\(\s*\d{1,5}\s*\)$"),
]
# Preset column definitions: fixed text, never built from input
PRESETS = {
    "customers": [
        ("id", "bigint generated always as identity primary key"),
        ("name", "text not null"),
        ("email", "varchar(120)"),
        ("city", "text"),
        ("created_at", "timestamptz not null default now()"),
    ],
    "orders": [
        ("id", "bigint generated always as identity primary key"),
        ("customer_id", "bigint not null"),
        ("amount", "numeric(12,2) not null"),
        ("status", "varchar(20) not null"),
        ("ordered_at", "timestamptz not null default now()"),
    ],
    "sales_events": [
        ("id", "bigint generated always as identity primary key"),
        ("event_time", "timestamptz not null"),
        ("region", "text"),
        ("product", "text"),
        ("quantity", "integer"),
        ("unit_price", "numeric(10,2)"),
        ("channel", "varchar(20)"),
    ],
}
# --where operators: the SQL text comes from this table only
OPS = {"=": "=", "!=": "<>", "<>": "<>", "<": "<", "<=": "<=", ">": ">", ">=": ">=",
       "like": "LIKE", "ilike": "ILIKE", "is null": "IS NULL", "is not null": "IS NOT NULL"}
WORDS = {
    "city": ["Bengaluru", "Pune", "Hyderabad", "Chennai", "Mumbai", "Delhi", "Austin", "Dublin", "Munich", "Sydney"],
    "region": ["north", "south", "east", "west", "central"],
    "status": ["new", "paid", "shipped", "delivered", "cancelled"],
    "product": ["widget", "gadget", "gizmo", "sprocket", "flange", "bracket"],
    "channel": ["web", "store", "partner", "phone"],
    "name": ["Asha Rao", "Ravi Kumar", "Meera Iyer", "John Smith", "Ana Silva", "Li Wei", "Omar Haddad", "Eva Novak"],
}


class Fail(Exception):
    pass


# ---------------------------------------------------------------- helpers
def K(text):
    """A fixed SQL fragment (keywords, or a type from the checked list)."""
    return sql.SQL(text)


def qname(name):
    """[schema.]table -> sql.Identifier, checking every part."""
    parts = name.split(".")
    if len(parts) > 2 or not all(IDENT.match(p) for p in parts):
        raise Fail(f"'{name}' is not a valid [schema.]name (letters, digits, _ and $; starts with a letter or _)")
    return sql.Identifier(*parts)


def split_name(name):
    parts = name.split(".")
    return (parts[0], parts[1]) if len(parts) == 2 else ("public", parts[0])


def column_type(t):
    """A column type from the fixed list (normalized), else Fail."""
    t = " ".join(t.strip().lower().split())
    if t == "identity":
        return "bigint generated always as identity"
    if any(p.match(t) for p in TYPE_PATTERNS):
        return t
    raise Fail(f"column type '{t}' is not accepted; use one of the types listed in --help")


def parse_columns(text):
    pieces = [c for c in (text or "").split(",") if c.strip()]
    merged, buf = [], ""
    for piece in pieces:   # numeric(12,2) holds a comma: re-join the pieces of one type
        buf = f"{buf},{piece}" if buf else piece
        if buf.count("(") == buf.count(")"):
            merged.append(buf)
            buf = ""
    if buf:
        raise Fail(f"unbalanced parentheses in --columns near '{buf}'")
    out = []
    for m in merged:
        if ":" not in m:
            raise Fail(f"'{m}' must be name:type")
        n, t = m.split(":", 1)
        n = n.strip()
        if not IDENT.match(n):
            raise Fail(f"column name '{n}' is not valid")
        out.append((n, column_type(t)))
    if not out:
        raise Fail("no columns given")
    return out


def connect(a, dbname=None, read_only=False):
    kw = dict(host=a.host, port=a.port, user=a.user, dbname=dbname or a.dbname, password=a.password,
              sslmode=a.sslmode, connect_timeout=10, application_name="pgdata")
    if read_only:
        # every transaction of this session is read-only unless it says otherwise
        kw["options"] = "-c default_transaction_read_only=on"
    if a.sslrootcert:
        kw["sslrootcert"] = a.sslrootcert
    try:
        return psycopg.connect(**kw)
    except psycopg.OperationalError as e:
        raise Fail(f"cannot connect to {a.host}:{a.port} as {a.user} (database {kw['dbname']}): {str(e).strip()}")


def need(a, *names):
    missing = [n for n in names if not getattr(a, n.replace("-", "_"), None)]
    if missing:
        raise Fail("missing: " + ", ".join("--" + n for n in missing))


# ---------------------------------------------------------------- commands
def cmd_create_db(a):
    need(a, "name")
    if not IDENT.match(a.name):
        raise Fail(f"database name '{a.name}' is not valid")
    with connect(a) as conn:
        conn.autocommit = True
        if conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (a.name,)).fetchone():
            if a.if_not_exists:
                print(f"database {a.name} already exists")
                return
            raise Fail(f"database {a.name} already exists (add --if-not-exists to accept that)")
        q = K("CREATE DATABASE ") + sql.Identifier(a.name)
        if a.owner:
            if not IDENT.match(a.owner):
                raise Fail(f"role name '{a.owner}' is not valid")
            q = q + K(" OWNER ") + sql.Identifier(a.owner)
        conn.execute(q)
    print(f"database {a.name} created")


def cmd_create_table(a):
    need(a, "database", "table")
    if bool(a.preset) == bool(a.columns):
        raise Fail("give either --preset or --columns")
    cols = PRESETS[a.preset] if a.preset else parse_columns(a.columns)
    parts = [sql.Identifier(n) + K(" ") + K(t) for n, t in cols]
    if a.primary_key:
        if a.primary_key not in [n for n, _ in cols]:
            raise Fail(f"--primary-key {a.primary_key} is not one of the columns")
        if any("primary key" in t for _, t in cols):
            raise Fail("the columns already define a primary key")
        parts.append(K("PRIMARY KEY (") + sql.Identifier(a.primary_key) + K(")"))
    q = K("CREATE TABLE IF NOT EXISTS " if a.if_not_exists else "CREATE TABLE ") + qname(a.table) \
        + K(" (") + K(", ").join(parts) + K(")")
    schema, _ = split_name(a.table)
    with connect(a, a.database) as conn:
        if "." in a.table:
            conn.execute(K("CREATE SCHEMA IF NOT EXISTS ") + sql.Identifier(schema))
        conn.execute(q)
    print(f"table {a.table} ready in database {a.database} ({len(cols)} columns)")


def table_columns(conn, table):
    schema, name = split_name(table)
    rows = conn.execute(
        # information_schema columns are domains (sql_identifier, character_data,
        # cardinal_number, yes_or_no): cast them so every driver returns str and int
        "SELECT column_name::text, data_type::text, udt_name::text, character_maximum_length::int,"
        " numeric_precision::int, numeric_scale::int, column_default::text, is_identity::text, is_generated::text"
        " FROM information_schema.columns WHERE table_schema = %s AND table_name = %s"
        " ORDER BY ordinal_position", (schema, name)).fetchall()
    if not rows:
        raise Fail(f"table {schema}.{name} not found (or no columns)")
    return rows


def generate(col, rnd, i):
    name, dtype, udt, maxlen, prec, scale = col[:6]
    lname = name.lower()
    if dtype == "smallint":
        return rnd.randint(0, 32000)
    if dtype == "integer":
        return rnd.randint(1, 1000) if lname.endswith(("quantity", "qty", "count")) else rnd.randint(0, 2_000_000)
    if dtype == "bigint":
        return rnd.randint(1, 10_000) if lname.endswith("_id") else rnd.randint(0, 10**12)
    if dtype in ("real", "double precision"):
        return round(rnd.uniform(0, 10000), 4)
    if dtype == "numeric":
        s = scale if scale is not None else 2
        p = prec if prec is not None else 12
        top = min(10 ** max(p - s, 1) - 1, 100000)
        return decimal.Decimal(str(round(rnd.uniform(0, top), s)))
    if dtype == "boolean":
        return rnd.random() < 0.5
    if dtype == "date":
        return dt.date.today() - dt.timedelta(days=rnd.randint(0, 730))
    if dtype.startswith("timestamp"):
        t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=rnd.randint(0, 730 * 86400))
        return t if "with time zone" in dtype else t.replace(tzinfo=None)
    if dtype == "uuid":
        return uuid.UUID(int=rnd.getrandbits(128), version=4)
    if dtype in ("json", "jsonb"):
        return Jsonb({"seq": i, "tag": rnd.choice(WORDS["region"]), "score": rnd.randint(0, 100)})
    if dtype in ("text", "character varying", "character"):
        if "email" in lname:
            v = f"user{rnd.randint(1, 10**6)}@example.com"
        else:
            key = next((k for k in WORDS if k in lname), None)
            v = rnd.choice(WORDS[key]) if key else "".join(rnd.choices(string.ascii_lowercase, k=rnd.randint(5, 16)))
        return v[:maxlen] if maxlen else v
    raise Fail(f"column {name}: type {dtype} ({udt}) is not supported by insert")


def cmd_insert(a):
    need(a, "database", "table")
    if a.rows < 1 or a.batch_size < 1:
        raise Fail("--rows and --batch-size must be at least 1")
    rnd = random.Random(a.seed)
    with connect(a, a.database) as conn:
        cols = table_columns(conn, a.table)
        fill = [c for c in cols
                if c[7] != "YES" and c[8] != "ALWAYS" and not (c[6] or "").startswith("nextval(")]
        if not fill:
            raise Fail(f"table {a.table} has no column to fill (all identity, serial or generated)")
        copy_sql = K("COPY ") + qname(a.table) + K(" (") \
            + K(", ").join(sql.Identifier(c[0]) for c in fill) + K(") FROM STDIN")
        done = 0
        while done < a.rows:
            n = min(a.batch_size, a.rows - done)
            with conn.cursor() as cur:
                with cur.copy(copy_sql) as cp:
                    for k in range(n):
                        cp.write_row([generate(c, rnd, done + k) for c in fill])
            conn.commit()
            done += n
            print(f"  {done}/{a.rows} rows", file=sys.stderr)
    print(f"{a.rows} rows inserted into {a.table} ({', '.join(c[0] for c in fill)})")


def text(v, null=""):
    """One value as text: JSON for json/jsonb values, true/false for booleans."""
    if v is None:
        return null
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, default=str)
    return str(v)


def render(rows, headers, fmt):
    if fmt == "json":
        print(json.dumps([dict(zip(headers, r)) for r in rows], default=str, indent=2))
        return
    if fmt == "csv":
        w = csv.writer(sys.stdout)
        w.writerow(headers)
        for r in rows:
            w.writerow([text(v) for v in r])
        return
    cells = [[text(v, "NULL") for v in r] for r in rows]
    widths = [min(max([len(h)] + [len(c[i]) for c in cells]), 60) for i, h in enumerate(headers)]
    print(" | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)))
    print("-+-".join("-" * w for w in widths))
    for c in cells:
        print(" | ".join(c[i][:widths[i]].ljust(widths[i]) for i in range(len(headers))))
    print(f"({len(rows)} row{'s' if len(rows) != 1 else ''})")


WHERE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_$]*)\s*(is not null|is null|!=|<>|<=|>=|=|<|>|ilike|like)\s*(.*)$", re.I)


def cmd_read(a):
    need(a, "database")
    with connect(a, a.database, read_only=bool(a.sql)) as conn:
        if a.sql:
            with conn.transaction():
                conn.execute("SET TRANSACTION READ ONLY")
                # prepare=True sends the statement with the extended protocol, which
                # accepts exactly one statement: "commit; drop ..." is refused
                # instead of running outside the read-only transaction
                try:
                    cur = conn.execute(a.sql, prepare=True)
                except psycopg.errors.SyntaxError as e:
                    raise Fail(f"--sql takes one SELECT statement: {str(e).strip()}")
                if cur.description is None:
                    raise Fail("the statement returned no rows")
                render(cur.fetchall(), [d.name for d in cur.description], a.format)
            return
        need(a, "table")
        cols = [c[0] for c in table_columns(conn, a.table)]
        q = K("SELECT count(*) FROM " if a.count else "SELECT * FROM ") + qname(a.table)
        params = []
        if a.where:
            m = WHERE.match(a.where)
            if not m:
                raise Fail("--where must be 'COLUMN OP VALUE' with OP one of = != < <= > >= like ilike, "
                           "or 'COLUMN is [not] null'")
            col, op, val = m.group(1), m.group(2).lower(), m.group(3).strip()
            if col not in cols:
                raise Fail(f"--where: column {col} is not in {a.table} ({', '.join(cols)})")
            if op in ("is null", "is not null"):
                q = q + K(" WHERE ") + sql.Identifier(col) + K(" " + OPS[op])
            else:
                if len(val) >= 2 and val[0] in "'\"" and val[-1] == val[0]:
                    val = val[1:-1]
                cast = K("::text") if op in ("like", "ilike") else K("")
                q = q + K(" WHERE ") + sql.Identifier(col) + cast + K(" " + OPS[op] + " %s")
                params.append(val)
        if not a.count:
            if a.order_by:
                if a.order_by not in cols:
                    raise Fail(f"--order-by: column {a.order_by} is not in {a.table}")
                q = q + K(" ORDER BY ") + sql.Identifier(a.order_by) + K(" DESC" if a.desc else " ASC")
            q = q + K(" LIMIT %s")
            params.append(a.limit)
        cur = conn.execute(q, params)
        render(cur.fetchall(), [d.name for d in cur.description], a.format)


COMMANDS = {"create-db": cmd_create_db, "create-table": cmd_create_table, "insert": cmd_insert, "read": cmd_read}


# ---------------------------------------------------------------- prompts
def ask(prompt, default=None, choices=None, secret=False, required=True):
    hint = f" [{default}]" if default not in (None, "") else ""
    if choices:
        hint += f" ({'/'.join(choices)})"
    while True:
        v = getpass.getpass(f"{prompt}: ") if secret else input(f"{prompt}{hint}: ").strip()
        if not v and default not in (None, ""):
            v = str(default)
        if choices and v not in choices:
            print(f"  choose one of {', '.join(choices)}")
            continue
        if v or not required:
            return v
        print("  a value is required")


def interactive(a):
    print("pgdata: connection (nothing is read from the cluster; see --help for how to reach the instance)")
    a.host = a.host or ask("host (Service address, or 127.0.0.1 with kubectl port-forward)")
    a.port = int(ask("port", a.port or 5432))
    a.user = a.user or ask("user (the username key of <instance>-db-secret)")
    a.dbname = ask("database to connect to", a.dbname or "postgres")
    a.sslmode = ask("sslmode", a.sslmode or "prefer",
                    ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"])
    if a.sslmode in ("verify-ca", "verify-full"):
        a.sslrootcert = a.sslrootcert or ask("CA certificate file (sslrootcert)")
    if not a.password:
        a.password = os.environ.get("PGPASSWORD") or ask("password (hidden)", secret=True)
    cmd = ask("action", "read", list(COMMANDS))
    if cmd == "create-db":
        a.name = ask("new database name")
        a.owner = ask("owner role (empty: the connecting user)", required=False) or None
        a.if_not_exists = ask("accept an existing database", "y", ["y", "n"]) == "y"
    elif cmd == "create-table":
        a.database = ask("database", a.dbname)
        a.table = ask("table ([schema.]name)")
        if ask("columns from", "preset", ["preset", "custom"]) == "preset":
            a.preset = ask("preset", "customers", list(PRESETS))
        else:
            cols = []
            print("  one column at a time; an empty name finishes. Types: see --help (identity for an id column)")
            while True:
                n = ask("  column name", required=False)
                if not n:
                    break
                cols.append(f"{n}:{ask(f'  type of {n}', 'text')}")
            a.columns = ",".join(cols)
            a.primary_key = ask("primary key column (empty: none)", required=False) or None
        a.if_not_exists = ask("accept an existing table", "y", ["y", "n"]) == "y"
    elif cmd == "insert":
        a.database = ask("database", a.dbname)
        a.table = ask("table ([schema.]name)")
        a.rows = int(ask("rows", 100))
        a.batch_size = int(ask("batch size", 1000))
        s = ask("random seed (empty: random)", required=False)
        a.seed = int(s) if s else None
    else:
        a.database = ask("database", a.dbname)
        if ask("read", "table", ["table", "sql"]) == "sql":
            a.sql = ask("SELECT statement (runs read only)")
        else:
            a.table = ask("table ([schema.]name)")
            a.count = ask("only count the rows", "n", ["y", "n"]) == "y"
            if not a.count:
                a.limit = int(ask("limit", 20))
                a.order_by = ask("order by column (empty: none)", required=False) or None
                a.desc = bool(a.order_by) and ask("descending", "n", ["y", "n"]) == "y"
            a.where = ask("filter, for example city = Pune (empty: none)", required=False) or None
        a.format = ask("format", "table", ["table", "csv", "json"])
    return cmd


def parser():
    p = argparse.ArgumentParser(prog="pgdata.py", description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("--host")
    p.add_argument("--port", type=int, default=5432)
    p.add_argument("--user")
    p.add_argument("--password", help="visible in the process list; prefer PGPASSWORD or the prompt")
    p.add_argument("--dbname", default="postgres", help="database for the connection (create-db)")
    p.add_argument("--sslmode", default="prefer",
                   choices=["disable", "allow", "prefer", "require", "verify-ca", "verify-full"])
    p.add_argument("--sslrootcert")
    p.add_argument("--interactive", "-i", action="store_true", help="ask for everything step by step")
    sub = p.add_subparsers(dest="command")
    c = sub.add_parser("create-db", help="create a database")
    c.add_argument("--name")
    c.add_argument("--owner")
    c.add_argument("--if-not-exists", action="store_true")
    t = sub.add_parser("create-table", help="create a table from a preset or a column list")
    t.add_argument("--database")
    t.add_argument("--table")
    t.add_argument("--preset", choices=list(PRESETS))
    t.add_argument("--columns", help='"name:type,..." for example "id:identity,name:text,amount:numeric(12,2)"')
    t.add_argument("--primary-key")
    t.add_argument("--if-not-exists", action="store_true")
    i = sub.add_parser("insert", help="insert random rows generated from the column types")
    i.add_argument("--database")
    i.add_argument("--table")
    i.add_argument("--rows", type=int, default=100)
    i.add_argument("--batch-size", type=int, default=1000)
    i.add_argument("--seed", type=int)
    r = sub.add_parser("read", help="read rows from a table, or run a read-only query")
    r.add_argument("--database")
    r.add_argument("--table")
    r.add_argument("--limit", type=int, default=20)
    r.add_argument("--where")
    r.add_argument("--order-by")
    r.add_argument("--desc", action="store_true")
    r.add_argument("--count", action="store_true")
    r.add_argument("--format", choices=["table", "csv", "json"], default="table")
    r.add_argument("--sql", help="a SELECT statement, run in a READ ONLY transaction")
    return p


DEFAULTS = dict(name=None, owner=None, if_not_exists=False, database=None, table=None, preset=None, columns=None,
                primary_key=None, rows=100, batch_size=1000, seed=None, limit=20, where=None, order_by=None,
                desc=False, count=False, format="table", sql=None)


def main(argv=None):
    a = parser().parse_args(argv)
    for k, v in DEFAULTS.items():
        if not hasattr(a, k):
            setattr(a, k, v)
    try:
        if a.interactive or not a.command:
            if not sys.stdin.isatty() and not a.interactive:
                parser().print_help()
                return 2
            cmd = interactive(a)
        else:
            cmd = a.command
            need(a, "host", "user")
            if not a.password:
                a.password = os.environ.get("PGPASSWORD") or getpass.getpass(f"password for {a.user}@{a.host}: ")
        COMMANDS[cmd](a)
        return 0
    except Fail as e:
        print(f"pgdata: {e}", file=sys.stderr)
        return 1
    except psycopg.Error as e:
        print(f"pgdata: {type(e).__name__}: {str(e).strip()}", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        print("\npgdata: cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
