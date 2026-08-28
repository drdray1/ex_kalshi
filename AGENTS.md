# AGENTS.md

## Project Overview

ExKalshi is an Elixir client for the Kalshi Trade API v2 (prediction markets). It provides
REST operations (exchange status, markets/events/series, orders V2, portfolio) with a
prediction-market helper layer, and a managed WebSocket connection for market data and
user channels.

## Build & Test

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix test --cover      # fails if total < 90%
mix test test/ex_kalshi/orders_test.exs:42
mix credo
mix format
mix format --check-formatted
```

## Architecture

- `ExKalshi` — public facade; `defdelegate` only, no logic
- `ExKalshi.Client` — builds `Req.Request` clients (`new/3` authenticated, `public/1`), base URLs
  (prod / demo, overridable via `config :ex_kalshi, :config`), `handle_response/1`
- `ExKalshi.Auth` — Req request step adding `KALSHI-ACCESS-KEY/TIMESTAMP/SIGNATURE`; signs
  `timestamp <> METHOD <> /trade-api/v2/<path-without-query>`
- `ExKalshi.Signature` — RSA-PSS/SHA-256 via `:public_key` (PKCS#1 and PKCS#8 PEM)
- `ExKalshi.Query` — whitelisted query builder; `csv/1` for comma-separated params
- `ExKalshi.Exchange / Markets / Events / Series / Orders / Portfolio` — one module per resource,
  raw string-keyed maps, `extract_*` helpers
- `ExKalshi.Predictions` — YES/NO helpers (`buy_yes`, `buy_no` ⇒ `ask @ 1-p`, …), fee math,
  orderbook best prices, Coinbase product-id bridge
- `ExKalshi.Orderbook` — parsed book struct + `apply_delta/5`
- `ExKalshi.WebSocket` — command builders, event structs, `parse_message/1`
- `ExKalshi.WebSocket.Client` — WebSockex wrapper (auth headers at handshake)
- `ExKalshi.WebSocket.Connection` — GenServer: lazy connect, sid/seq tracking, gap resubscribe,
  backoff reconnect, `{:kalshi_event, type, event}` fan-out

### Key patterns

- All API functions return `{:ok, map}` / `{:error, reason}`; error atoms `:unauthorized`,
  `:forbidden`, `:not_found`, `:rate_limited`, plus `{:api_error, status, msg}`,
  `{:connection_error, r}`, `{:validation_error, [msg]}`, `{:signature_failed, r}`
- Orders are always on the YES leg (`bid`/`ask`); prices are 4-dp dollar strings, counts 2-dp
- Write requests (`Orders.*`) send `retry: false` — never replay a POST/DELETE
- Only `*_dollars` / `*_fp` fixed-point fields are used; integer-cent fields are deprecated

### API reference

https://docs.kalshi.com — OpenAPI at `/openapi.yaml`, AsyncAPI at `/asyncapi.yaml`.

## Testing

- HTTP: `Req.Test` plugs; `ExKalshi.Fixtures.test_client/1` and `public_client/1`
- Assert exact `conn.query_string` and decoded JSON bodies in endpoint tests
- A throwaway RSA key is generated at compile time in `test/support/fixtures.ex`
- Mimic for `WebSockex` and `ExKalshi.WebSocket.Client` (global mode, `async: false`)
- Test files mirror `lib/`

## Code Style

- `mix format`; `@moduledoc` + `@spec` on every public module/function
- Private helpers at the bottom under a `# Private Functions` banner
