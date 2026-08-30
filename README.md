# ExKalshi

Elixir client for the [Kalshi Trade API v2](https://docs.kalshi.com) — prediction markets.

REST (markets, events, series, orders V2, portfolio) with a YES/NO helper layer, plus a
managed WebSocket connection for orderbooks, tickers, trades, fills and order updates.

## Installation

```elixir
def deps do
  [
    {:ex_kalshi, git: "https://github.com/drdray1/ex_kalshi.git", tag: "0.1.1"}
  ]
end
```

## Authentication

Create an API key at <https://kalshi.com/account/profile> (demo: <https://demo.kalshi.co>).
Kalshi gives you a **Key ID** and an **RSA private key** (PEM). Both PKCS#1
(`BEGIN RSA PRIVATE KEY`) and PKCS#8 (`BEGIN PRIVATE KEY`) encodings work.

```elixir
client = ExKalshi.new("your-key-id", File.read!("kalshi.pem"))
demo   = ExKalshi.new("your-demo-key-id", File.read!("demo.pem"), demo: true)
public = ExKalshi.public()   # no key needed for market data
```

Every request is signed with RSA-PSS/SHA-256 over `timestamp + METHOD + path`.

## Quick start

```elixir
{:ok, %{"exchange_active" => true}} = ExKalshi.exchange_status(public)

{:ok, markets} = ExKalshi.list_all_markets(public, series_ticker: "KXBTC15M", status: "open")
ExKalshi.market_summary(hd(markets))
# %{ticker: "KXBTC15M-26AUG272300-00", yes_bid: Decimal.new("0.55"), yes_ask: Decimal.new("0.57"), ...}

{:ok, %{"balance_dollars" => balance}} = ExKalshi.get_balance(client)

# Buy 10 YES at $0.56 — Kalshi always quotes the YES leg
{:ok, %{"order_id" => id}} =
  ExKalshi.buy_yes(client, "KXBTC15M-26AUG272300-00", 10, 0.56, client_order_id: "my-id")

# Buy NO at $0.30 is sent as ask YES at $0.70
{:ok, _} = ExKalshi.buy_no(client, "KXBTC15M-26AUG272300-00", 10, 0.30)

{:ok, _} = ExKalshi.cancel_order(client, id)
```

## REST API

### Exchange
```elixir
ExKalshi.Exchange.status(public)
ExKalshi.Exchange.schedule(public)
```

### Markets / Events / Series
```elixir
ExKalshi.Markets.list_markets(public, event_ticker: "KXBTC15M-26AUG272300", limit: 100)
ExKalshi.Markets.get_market(public, "KXBTC15M-26AUG272300-00")
ExKalshi.Markets.get_orderbook(client, "KXBTC15M-26AUG272300-00", depth: 10)   # auth required
ExKalshi.Markets.list_trades(public, ticker: "KXBTC15M-26AUG272300-00")
ExKalshi.Markets.get_candlesticks(public, "KXBTC15M", "KXBTC15M-26AUG272300-00",
  start_ts: 1_756_300_000, end_ts: 1_756_330_000, period_interval: 1)   # 1 | 60 | 1440
ExKalshi.Events.list_events(public, series_ticker: "KXBTC15M", with_nested_markets: true)
ExKalshi.Series.get_series(public, "KXBTC15M")
```

### Orders (V2)
```elixir
ExKalshi.Orders.create_order(client,
  ticker: "KXBTC15M-26AUG272300-00", side: "bid", count: 10, price: 0.56,
  time_in_force: "immediate_or_cancel", client_order_id: "abc", reduce_only: true)
ExKalshi.Orders.batch_create_orders(client, [order1, order2])
ExKalshi.Orders.cancel_order(client, order_id)
ExKalshi.Orders.amend_order(client, order_id, ticker: t, side: "bid", price: 0.6, count: 12)
ExKalshi.Orders.decrease_order(client, order_id, reduce_by: 3)
ExKalshi.Orders.list_orders(client, ticker: t, status: "resting")
ExKalshi.Orders.find_by_client_order_id(client, "abc", ticker: t)
```

Write requests are never retried at the HTTP layer. After a transport error, look the order
up by `client_order_id` before assuming it was rejected.

### Portfolio
```elixir
ExKalshi.Portfolio.get_balance(client)
ExKalshi.Portfolio.list_positions(client, ticker: t)     # position_fp: +YES / −NO
ExKalshi.Portfolio.list_fills(client, order_id: id)
ExKalshi.Portfolio.list_settlements(client)
```

### Prediction-market helpers
```elixir
alias ExKalshi.{Predictions, Orderbook}

Predictions.estimate_fee(100, 0.50)          # Decimal "1.75" (0.07·C·p·(1−p), ceil to cent)
Predictions.no_to_yes_price(0.30)            # Decimal "0.70"
Predictions.position_side(%{"position_fp" => "-4.00"})   # :no

{:ok, raw} = ExKalshi.get_orderbook(client, t)
book = Orderbook.from_rest(raw, t)
Predictions.best_yes_bid(book); Predictions.best_yes_ask(book); Predictions.spread(book)

Predictions.to_coinbase_product_id("KXBTC15M-26AUG272300-00")   # "...-KALSHI"
```

## WebSocket streaming

```elixir
{:ok, conn} = ExKalshi.WebSocket.Connection.start_link(
  key_id: "your-key-id", private_key_pem: pem, demo: true)

ExKalshi.WebSocket.Connection.add_subscriber(conn, self())
ExKalshi.WebSocket.Connection.subscribe(conn, [:ticker, :orderbook_delta], ["KXBTC15M-26AUG272300-00"])
ExKalshi.WebSocket.Connection.subscribe(conn, [:fill, :user_orders])

receive do
  {:kalshi_event, :orderbook_snapshot, %ExKalshi.WebSocket.OrderbookSnapshotEvent{book: book}} -> book
  {:kalshi_event, :orderbook_delta, %ExKalshi.WebSocket.OrderbookDeltaEvent{} = d} ->
    ExKalshi.Orderbook.apply_delta(book, d.side, d.price, d.delta, d.seq)
  {:kalshi_event, :fill, %ExKalshi.WebSocket.FillEvent{order_id: id}} -> id
end
```

The connection authenticates at the handshake, replays subscriptions after a reconnect,
and resubscribes a channel when it sees a `seq` gap. Omit the credentials for a public-only
connection (`ticker`, `trade`, `market_lifecycle_v2`).

## Configuration

```elixir
config :ex_kalshi, :config,
  base_url: "https://external-api.kalshi.com/trade-api/v2",
  demo_url: "https://external-api.demo.kalshi.co/trade-api/v2",
  websocket_url: "wss://external-api-ws.kalshi.com/trade-api/ws/v2",
  demo_websocket_url: "wss://external-api-ws.demo.kalshi.co/trade-api/ws/v2",
  timeout: 30_000
```

## Testing in your app

```elixir
client = ExKalshi.new(key_id, pem, plug: {Req.Test, MyApp.KalshiStub})
Req.Test.stub(MyApp.KalshiStub, fn conn -> Req.Test.json(conn, %{"balance_dollars" => "10.00"}) end)
```

## License

MIT
