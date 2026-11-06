# libpgsql

A PostgreSQL client for Echo. Protocol 3.0 and 3.2 over libtcp: login, queries, COPY, pipelining, a connection pool. No C, no libpq, no TLS yet.

- `query` when you want the rows. `exec` when you want `affectedRows`. `stream` when you cannot hold the result.
- `$1` positional, `:name` in a map. `RETURNING` for the row you just wrote.
- Prepared SQL stays on the connection. Same SQL next time is one round trip, rows in binary.
- A transaction rolls back if you drop it.
- A `Pool` shares connections across threads. A lease goes back when dropped.
- `COPY` for bulk in and out. A `Pipeline` sends many statements in one round trip.
- SCRAM-SHA-256 login works, md5 and trust too. Clear-text passwords only on a unix socket (or `allowCleartext`).

## Installation

From your project directory:

```bash
epm add echolang/libpgsql --git https://github.com/echolang/libpgsql --range ^0.1
```

That writes a `#[requires:]` line and vendors the sources. libtcp and libcrypto come along as requires. Echo sees the `pgsql` namespace as soon as the module loads. There is no C of its own.

## Quick start

Open, `exec`, `query`, close:

```echo
pgsql::Connection $db = guard pgsql::Connection::open('postgres://app:secret@127.0.0.1/shop') else ($e) {
    die("connect: {$e}");
}

pgsql::Outcome $lamp = guard $db->exec(
    'INSERT INTO products (name, price, stock) VALUES (:name, :price, :stock)',
    ['name' => 'Lamp', 'price' => .numeric('49.90'), 'stock' => 12],
) else ($e) {
    die("insert: {$e}");
}
echo "inserted {$lamp->affectedRows}";

pgsql::ResultSet $rows = guard $db->query(
    'SELECT name, stock FROM products WHERE name = $1',
    ['Lamp'],
) else ($e) {
    die("{$e}");
}
foreach ($rows as $row) {
    int64 $stock = $row['stock']->int() ?? 0;
    echo "{$row['name']}: {$stock} in stock";
}

$db->close();
```

`exec` is the statement that returns no rows. `query` buffers the result. A URL is enough for `Connection::open`; `Options` is the same thing when you want to set a field after parsing.

Here is the catch: `exec` with no values is the simple protocol, one round trip, and it can be several statements. Values mean a prepared statement. The connection keeps the ones it has seen, so the next run of the same SQL is just an execute, and `query` gets its rows in binary.

PostgreSQL does not hand you a last-insert-id. Ask for it:

```echo
pgsql::ResultSet $row = guard $db->query(
    'INSERT INTO products (name, stock) VALUES (:name, :stock) RETURNING id',
    ['name' => 'Desk', 'stock' => 3],
) else ($e) {
    die("{$e}");
}
echo $row[0]['id'];
```

## Connecting

A URL names the server: `postgres://user:password@host:port/database?...`, or `postgresql://`. User, password, host and database are percent-decoded. A host that starts with `/` is a unix socket directory.

Query keys, named as libpq names them: `host`, `port`, `user`, `password`, `dbname`, `sslmode`, `application_name`, `connect_timeout` (seconds), `options` (sent as is). And this library's own: `timeout` and `cancel_wait` (`250ms`, `5s`, `2m`), `statement_cache`, `max_message`, `max_protocol_version` (`3.0` or `3.2`), `allow_cleartext`.

```echo
pgsql::Connection $db = guard pgsql::Connection::open('postgres://app:secret@127.0.0.1/shop') else ($e) {
    die("{$e}");
}
```

`Options` is plain data. Fields with defaults, set by name at construction or by assignment:

```echo
pgsql::Options $o = pgsql::Options($user: 'app', $password: 'secret', $database: 'shop');
$o->socket = '/var/run/postgresql';
$o->timeout = time::duration::secs(10);

pgsql::Connection $db = guard pgsql::Connection::open($o) else ($e) {
    die("{$e}");
}
```

When `socket` is set, `host` is not used. A directory gets `.s.PGSQL.{port}` added; a path that already names the socket file is taken as it is. That is the local path: no TLS, and the password never crosses the network.

`$db->server` is the version string (`server_version`). `$db->key` is what a cancel request has to show. One thread at a time (`cancel` aside). It is `#[atomic]` so a pool can hand it from one thread to the next.

`sslmode=disable`, `allow` and `prefer` all connect in plain, the way libpq does against a server without TLS. `require`, `verify-ca` and `verify-full` are refused at `open`: this client has no TLS yet.

Protocol 3.2 (PostgreSQL 18) brings longer cancel keys. Ask for it with `max_protocol_version=3.2`. An older server answers with the version it speaks and the session goes on in that one.

SCRAM-SHA-256 is the login a current server asks for. md5 and trust work too. Clear-text over TCP needs `Options->allowCleartext`. A unix socket always may.

## Queries

`query` reads the whole result into a `ResultSet`. `exec` is the same command when you only care what it did: `affectedRows`, `command` (`INSERT`, `UPDATE`, `SELECT`, `CREATE`). `stream` is the one that does not buffer.

```echo
pgsql::ResultSet $rows = guard $db->query('SELECT name, price FROM products') else ($e) {
    die("{$e}");
}

pgsql::Outcome $sold = guard $db->exec('UPDATE products SET stock = stock - 1 WHERE name = $1', ['Lamp']) else ($e) {
    die("{$e}");
}
echo "touched {$sold->affectedRows}";
```

Values in the call mean a prepared statement. The connection keeps the ones it has seen (`Options->statementCache`, 64 by default) so the next run of the same SQL is one round trip. Zero cache runs every query as an unnamed statement: still one round trip, but rows come back as text. `prepare` is when you want the `Statement` in your hand, to run many times with different params and close it yourself.

`batch` is every result of a script of several statements, in order. No values, so the simple protocol, and rows arrive as text.

## Params

Write them as a literal where the params go. An array for `$1`, `$2`, ..., a map for `:name`. A literal holds one value just as well: `['Lamp']`.

```echo
$db->exec('INSERT INTO products (name, price, stock) VALUES ($1, $2, $3)', ['Desk', .numeric('10.00'), 3]);
$db->exec('INSERT INTO products (name, price, stock) VALUES (:name, :price, :stock)', [
    'name'  => 'Lamp',
    'price' => .numeric('49.90'),
    'stock' => 12,
]);
```

A repeated `:name` is one parameter: `SELECT :x + :y + :x` takes two values. Mixing `$1` and `:name` in one SQL is `.invalid`. JSONB operators (`?`, `?|`) are left alone, so `data ? 'k'` is not a placeholder.

To keep going after the literal, start a chain with `.of([...])` or `.named([...])` and add to it. Code that builds params in a loop starts from an empty one (`pgsql::Params $values = []`, then `$values[] = $v` or `$values['name'] = $v`).

An array is one value. `ANY($1)` is how several ids become one parameter:

```echo
array<int64> $ids = [1, 2, 3];
$db->query('SELECT name, stock FROM products WHERE id = ANY($1)', [$ids]);
```

A `NUMERIC` stays a numeric, as the server wrote it, so nothing is rounded. Integers, floats, bools, strings, dates, uuids, intervals, and arrays convert on the way in. An Echo `null` is SQL NULL:

```echo
string? $note = null;
$db->exec('UPDATE products SET note = :note WHERE name = :name', ['note' => $note, 'name' => 'Rug']);
```

Mixing `add` and `set` on one `Params` is `.invalid`. A value with no placeholder, or a placeholder with no value, is too. The count has to match.

## Rows

`$row['name']` and `$row[0]` read a value. `foreach ($row as $name => $value)` walks them. Typed reads answer null when the value is not that type, so `??` does the rest:

```echo
foreach ($rows as $row) {
    int64 $stock = $row['stock']->int() ?? 0;
    echo "{$row['name']}: {$row['price']} ({$stock} in stock)";
}
```

`$row['price']` interpolates as the server sent it. A NUMERIC stays a string of digits. `int()`, `float()`, `text()`, `numeric()`, `bool()`, `json()` are the typed reads. `isNull()` is SQL NULL. JSON and JSONB arrive as text; parsing them is a JSON library's job. A type this library does not decode (an enum, a range, an inet) arrives as text too.

A name the result does not have stops the program, in a release build too: it is a mistake in the code, not in the data. `get` is the lookup that cannot stop.

`$rows[0]` is the first row of a `ResultSet`. Past the last row stops the same way. `first()` answers null when there are none.

## Stream

A result too big to hold: rows one at a time. While it is open the connection answers `.busy`. Reaching the end, `finish()`, or dropping it frees the connection again.

`foreach` (or `next()`) hands out each row decoded whole:

```echo
pgsql::Rows $stream = guard $db->stream('SELECT id, name, note FROM products ORDER BY id') else ($e) {
    die("{$e}");
}
foreach ($stream as $row) {
    string $note = $row['note']->text() ?? '-';
    echo "#{$row['id']} {$row['name']} {$note}";
}
guard $stream->finish() else ($e) {
    die("{$e}");
}
```

`finish` is also where a `foreach` error shows up: iteration cannot hand one back, so you ask after.

`step` with `view` reads the row in place, column by column. Nothing is decoded until it is asked for. Code that maps rows onto its own types finds each column once, then reads by position:

```echo
pgsql::Rows $raw = guard $db->stream('SELECT name, stock FROM products ORDER BY id') else ($e) {
    die("{$e}");
}
usize $stockAt = $raw->columns()->find('stock') ?? 0;
int64 $units = 0;
while (true) {
    bool $more = guard $raw->step() else ($e) {
        die("{$e}");
    }
    if (!$more) {
        break;
    }
    $units = $units + ($raw->view()->int($stockAt) ?? 0);
}
```

The view holds until the next move. A position past the last column stops the program.

## Transactions

`$db->transaction(...)` runs the work, commits on `.ok`, rolls back on `.error` (and hands that error on):

```echo
guard $db->transaction(function(pgsql::Connection $tx) : status<pgsql::Error> {
    guard $tx->exec('UPDATE products SET stock = stock - 1 WHERE name = $1', ['Chair']) else ($e) {
        return .error($e);
    }
    guard $tx->exec('UPDATE products SET note = $1 WHERE name = $2', ['last one soon', 'Chair']) else ($e) {
        return .error($e);
    }
    return .ok;
}) else ($e) {
    die("transaction: {$e}");
}
```

The generic form hands back a value: `transaction<T>(function(Connection) : result<T, Error>)`.

`begin()` if you want the handle. `begin(pgsql::Isolation::serializable)` if you want the isolation too, `true` as the second argument for read-only. `commit()` makes it stick. Dropping a `Transaction` without a commit rolls it back, so a `guard ... else { return ... }` cannot leave one half done.

## Pool

Connections shared by many threads. `query`, `exec`, and `transaction` take a lease around one call:

```echo
pgsql::Pool $pool = pgsql::Pool($options, pgsql::PoolOptions($max: 4));
pgsql::ResultSet $count = guard $pool->query('SELECT COUNT(*) AS n FROM products') else ($e) {
    die("{$e}");
}
echo "the pool counts {$count[0]['n']} products";
$pool->close();
```

`acquire` lends one out as a `Lease`. It goes back when dropped, or at `release()`. A thread that finds every connection lent out waits its turn: first come, first served.

A lease dropped mid-transaction is rolled back, so the next borrower does not inherit it. A dead, busy, too old, or surplus connection is closed instead of lent. An idle one older than `pingAfterIdle` is pinged first.

`.exhausted` when none came free before the deadline. `PoolOptions` defaults: 10 connections, 10 idle, 10 minutes idle, 30 seconds to acquire.

## COPY

Many rows in, or many rows out, without a query per row. The connection is `.busy` until the COPY finishes.

`copyIn(table: $table, $columns)` is the fast way in: `row` encodes each value for its column's type. Binary when every column has a binary form here; a NUMERIC or an enum falls back to text.

```echo
array<string> $cols = ['name', 'stock'];
pgsql::CopyIn $in = guard $db->copyIn(table: 'products', $cols) else ($e) {
    die("{$e}");
}
guard $in->row(['Lamp', 12]) else ($e) {
    die("{$e}");
}
guard $in->row(['Desk', 3]) else ($e) {
    die("{$e}");
}
pgsql::Outcome $copied = guard $in->finish() else ($e) {
    die("{$e}");
}
echo "copied {$copied->affectedRows}";
```

`copyIn('COPY products FROM STDIN')` takes the SQL as written. Then `row` is tab-separated text, or `write` sends the bytes as they are.

A bad row fails the whole COPY, and nothing is copied. Dropping a `CopyIn` without `finish` aborts it. Same idea as a transaction: leaving early cannot leave a half-written table.

`copyOut` is the other direction. `next()` hands out each chunk the server sends, until null:

```echo
pgsql::CopyOut $out = guard $db->copyOut('COPY products (name, stock) TO STDOUT') else ($e) {
    die("{$e}");
}
while (true) {
    string::view? $chunk = guard $out->next() else ($e) {
        die("{$e}");
    }
    string::view $line = guard $chunk else {
        break;
    };
    echo $line;
}
```

## Pipeline

Statements sent together and answered together: one round trip for all of them (two when some SQL is new to the connection, which is prepared first in one more).

```echo
pgsql::Pipeline $p = $db->pipeline();
foreach ($names as const &$name) {
    $p->add('INSERT INTO products (name, stock) VALUES (:name, 1)', ['name' => $name]);
}
array<pgsql::ResultSet> $done = guard $p->run() else ($e) {
    die("{$e}");
}
```

They run in order as one implicit transaction: when one fails, the ones before it are rolled back and the ones after it never run. Inside an explicit transaction they are part of that one instead. The statements stay, so the same pipeline runs again. `$p->failedAt()` is the position of the one that failed.

## Errors

Every call that can fail returns `result<T, Error>` or `status<Error>`. `guard` is the short way through. `"{$e}"` is the sentence. `name()` is the case without a match: `'server'`, `'timeout'`, and so on.

```echo
result<pgsql::Outcome, pgsql::Error> $again = $db->exec(
    'INSERT INTO products (name, price, stock) VALUES ($1, 1, 1)',
    ['Lamp'],
);
if ($again->failed() && $again->failure()->is(.uniqueViolation)) {
    echo 'Lamp is already there';
}
```

`$e->is(.uniqueViolation)` is the server's SQLSTATE. `$e->retryable()` is a serialization failure or a deadlock, where the server rolled the transaction back. `$e->state()` is the five characters (`23505`, `40001`), or null when the error did not come from the server.

| Case | Means |
|---|---|
| `server` | the server refused the command, with its SQLSTATE and message |
| `transport` | the socket failed: refused, reset, closed by the peer |
| `timeout` | the deadline passed first; the running statement is cancelled |
| `closed` | the connection is closed, or an earlier failure left it unusable |
| `busy` | a stream, a COPY or a pipeline is still open on this connection |
| `auth` | login failed on this side (unsupported method, cleartext over TCP, ...) |
| `malformed` | the server sent something that does not parse |
| `tooLarge` | a message over `Options->maxMessage` |
| `invalid` | the call could not be made as written |
| `exhausted` | no pooled connection came free in time |

A timeout sends a cancel. When the server does not answer that cancel in `cancelWait` (2 seconds), the connection closes. An error packet from the server ends the command and the connection is ready again.

## Timeouts

Every call takes `by:`. The one it named, else `Options->timeout` from now, else never. `connectTimeout` (10 seconds) bounds connecting and logging in, together.

```echo
pgsql::ResultSet $rows = guard $db->query('SELECT 1', by: tcp::Deadline(ms: 500)) else ($e) {
    die("{$e}");
}
```

`pgsql::cancel($options, $db->key)` asks the server to stop what that session is running, over a connection of its own, from any thread. Whether a statement was running, and stopped, shows on the session itself (`.queryCanceled`).

## What is not here

These are deliberate.

- **TLS.** Plain TCP, or a unix socket, or a tunnel in front. `sslmode=require` cannot be met, so `open` refuses it.
- **Kerberos, GSSAPI, SSPI.** The server asked for a method this client does not speak. That is `.auth`.
- **libpq.** The protocol is Echo over libtcp.
- **A JSON parser.** JSON and JSONB arrive as text.
- **NUMERIC in binary COPY.** `copyIn(table:, $columns)` runs that COPY as text.

## Working here

```bash
echoc test
```

No server. Protocol, params, rows, errors, the pool's queue. Against a real one:

```bash
scripts/test-live.sh                          # postgres:18-alpine in Docker
IMAGE=postgres:13-alpine scripts/test-live.sh
```

The server gets one role per authentication method: `app` (SCRAM-SHA-256), `app_md5`, `app_clear`, and `trusty`.

## License

MIT. Copyright Mario Döring.
