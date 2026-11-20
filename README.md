# bank-ledger-ruby

A small double-entry **bank ledger HTTP API in Ruby** (Sinatra + Sequel + SQLite): accounts, deposits, withdrawals and transfers, with idempotent requests and an audit trail of every balance change.

It is the Ruby counterpart of my Go project, [bank-ledger-go](https://github.com/miguelpavajeau/bank-ledger-go). Same domain and API, so I could compare how each language handles money correctness, errors and concurrency.

## Design decisions

| Concern | Decision |
|---|---|
| Money | `Integer` minor units (cents). Floats are rejected with `InvalidAmount`. |
| Atomicity | Each operation runs in one `DB.transaction`. A failed transfer leaves both balances untouched. |
| Overdrafts | Debits use `UPDATE ... WHERE balance >= amount`, so they are impossible under concurrent requests. A `CHECK (balance >= 0)` constraint backs it up. |
| Audit trail | Every operation writes signed rows in `entries`. |
| Retries | `Idempotency-Key` header. Same key and body replays the stored result (`200` + `Idempotent-Replayed: true`); same key with a different body returns `409`. |
| Errors | A small hierarchy under `Ledger::Error`, mapped to HTTP statuses in one table in `app.rb`. Unexpected errors return a generic `500`, never internals. |
| Layout | `lib/ledger.rb` has no HTTP knowledge; `app.rb` is a thin Sinatra layer, so the domain is testable on its own. |

## API

| Method | Path | Body |
|---|---|---|
| `POST` | `/accounts` | `{"owner":"ana","currency":"COP"}` |
| `GET` | `/accounts/:id` | |
| `GET` | `/accounts/:id/transactions` | |
| `POST` | `/accounts/:id/deposits` | `{"amount_minor":100000}` |
| `POST` | `/accounts/:id/withdrawals` | `{"amount_minor":5000}` |
| `POST` | `/transfers` | `{"from_account":"...","to_account":"...","amount_minor":25000}` |
| `GET` | `/healthz` | |

Errors return `{"error": "..."}` with `400`, `404`, `409` (idempotency conflict) or `422` (insufficient funds, currency mismatch).

## Run

```bash
bundle install
bundle exec rackup            # http://localhost:9292, database in ./ledger.db
curl -X POST localhost:9292/accounts -d '{"owner":"ana","currency":"COP"}'
```

Or with Docker: `docker build -t bank-ledger-ruby . && docker run -p 9292:9292 -v ledger-data:/data bank-ledger-ruby`.

`LEDGER_DB` sets the database URL (default `sqlite://ledger.db`).

## Test

```bash
bundle exec rake test
```

Minitest covers validation, atomic failure of transfers, idempotency replay and conflict, HTTP status mapping (with `rack-test`), and a test that runs 60 competing transfers from threads and asserts money is conserved and no balance goes negative.

## Limitations (on purpose)

- SQLite with a single connection keeps the example simple; production would use PostgreSQL with row-level locking.
- No authentication, rate limiting or pagination yet.
- Idempotency keys are global; a real API would scope them per client.

## About this repo

I wrote this with the help of Claude Code and reviewed the code and tests myself.
