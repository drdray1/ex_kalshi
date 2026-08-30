defmodule ExKalshi do
  @moduledoc """
  Elixir client for the [Kalshi Trade API v2](https://docs.kalshi.com).

  ## Quick start

      client = ExKalshi.new("your-key-id", File.read!("kalshi.pem"), demo: true)

      {:ok, %{"balance_dollars" => balance}} = ExKalshi.get_balance(client)
      {:ok, markets} = ExKalshi.list_all_markets(client, series_ticker: "KXBTC15M", status: "open")
      {:ok, order} = ExKalshi.buy_yes(client, "KXBTC15M-26AUG272300-00", 10, 0.56, client_order_id: "abc")

  Public data needs no key:

      public = ExKalshi.public()
      {:ok, status} = ExKalshi.exchange_status(public)

  Streaming lives in `ExKalshi.WebSocket.Connection`.

  Every function returns `{:ok, map}` or `{:error, reason}` where `reason` is
  `:unauthorized`, `:forbidden`, `:not_found` (or `{:not_found, detail}` when Kalshi
  names a code, e.g. `user_not_found`), `:rate_limited`,
  `{:api_error, status, message}`, `{:connection_error, term}`,
  `{:validation_error, [String.t()]}` or `{:signature_failed, term}`.
  """

  alias ExKalshi.{Client, Events, Exchange, Markets, Orders, Portfolio, Predictions, Series}

  @type client :: Client.client()

  # ============================================================================
  # Client
  # ============================================================================

  @doc "Creates an authenticated client. See `ExKalshi.Client.new/3`."
  @spec new(String.t(), String.t(), keyword()) :: client()
  defdelegate new(key_id, private_key_pem, opts \\ []), to: Client

  @doc "Creates an unauthenticated client. See `ExKalshi.Client.public/1`."
  @spec public(keyword()) :: client()
  defdelegate public(opts \\ []), to: Client

  @doc "Verifies credentials. See `ExKalshi.Client.verify_credentials/3`."
  defdelegate verify_credentials(key_id, private_key_pem, opts \\ false), to: Client

  # ============================================================================
  # Exchange
  # ============================================================================

  @doc "See `ExKalshi.Exchange.status/1`."
  defdelegate exchange_status(client), to: Exchange, as: :status

  @doc "See `ExKalshi.Exchange.schedule/1`."
  defdelegate exchange_schedule(client), to: Exchange, as: :schedule

  # ============================================================================
  # Markets / Events / Series
  # ============================================================================

  @doc "See `ExKalshi.Markets.list_markets/2`."
  defdelegate list_markets(client, opts \\ []), to: Markets

  @doc "See `ExKalshi.Markets.list_all_markets/2`."
  defdelegate list_all_markets(client, opts \\ []), to: Markets

  @doc "See `ExKalshi.Markets.get_market/2`."
  defdelegate get_market(client, ticker), to: Markets

  @doc "See `ExKalshi.Markets.get_orderbook/3`."
  defdelegate get_orderbook(client, ticker, opts \\ []), to: Markets

  @doc "See `ExKalshi.Markets.list_trades/2`."
  defdelegate list_trades(client, opts \\ []), to: Markets

  @doc "See `ExKalshi.Markets.get_candlesticks/4`."
  defdelegate get_candlesticks(client, series_ticker, ticker, opts), to: Markets

  @doc "See `ExKalshi.Events.list_events/2`."
  defdelegate list_events(client, opts \\ []), to: Events

  @doc "See `ExKalshi.Events.get_event/3`."
  defdelegate get_event(client, event_ticker, opts \\ []), to: Events

  @doc "See `ExKalshi.Series.list_series/2`."
  defdelegate list_series(client, opts \\ []), to: Series

  @doc "See `ExKalshi.Series.get_series/2`."
  defdelegate get_series(client, series_ticker), to: Series

  # ============================================================================
  # Orders
  # ============================================================================

  @doc "See `ExKalshi.Orders.create_order/2`."
  defdelegate create_order(client, params), to: Orders

  @doc "See `ExKalshi.Orders.batch_create_orders/2`."
  defdelegate batch_create_orders(client, orders), to: Orders

  @doc "See `ExKalshi.Orders.cancel_order/3`."
  defdelegate cancel_order(client, order_id, opts \\ []), to: Orders

  @doc "See `ExKalshi.Orders.batch_cancel_orders/2`."
  defdelegate batch_cancel_orders(client, order_ids), to: Orders

  @doc "See `ExKalshi.Orders.amend_order/3`."
  defdelegate amend_order(client, order_id, params), to: Orders

  @doc "See `ExKalshi.Orders.decrease_order/3`."
  defdelegate decrease_order(client, order_id, params), to: Orders

  @doc "See `ExKalshi.Orders.list_orders/2`."
  defdelegate list_orders(client, opts \\ []), to: Orders

  @doc "See `ExKalshi.Orders.get_order/2`."
  defdelegate get_order(client, order_id), to: Orders

  @doc "See `ExKalshi.Orders.find_by_client_order_id/3`."
  defdelegate find_by_client_order_id(client, client_order_id, opts \\ []), to: Orders

  # ============================================================================
  # Portfolio
  # ============================================================================

  @doc "See `ExKalshi.Portfolio.get_balance/2`."
  defdelegate get_balance(client, opts \\ []), to: Portfolio

  @doc "See `ExKalshi.Portfolio.list_positions/2`."
  defdelegate list_positions(client, opts \\ []), to: Portfolio

  @doc "See `ExKalshi.Portfolio.list_fills/2`."
  defdelegate list_fills(client, opts \\ []), to: Portfolio

  @doc "See `ExKalshi.Portfolio.list_settlements/2`."
  defdelegate list_settlements(client, opts \\ []), to: Portfolio

  # ============================================================================
  # Predictions
  # ============================================================================

  @doc "See `ExKalshi.Predictions.buy_yes/5`."
  defdelegate buy_yes(client, ticker, count, price, opts \\ []), to: Predictions

  @doc "See `ExKalshi.Predictions.sell_yes/5`."
  defdelegate sell_yes(client, ticker, count, price, opts \\ []), to: Predictions

  @doc "See `ExKalshi.Predictions.buy_no/5`."
  defdelegate buy_no(client, ticker, count, price, opts \\ []), to: Predictions

  @doc "See `ExKalshi.Predictions.sell_no/5`."
  defdelegate sell_no(client, ticker, count, price, opts \\ []), to: Predictions

  @doc "See `ExKalshi.Predictions.estimate_fee/3`."
  defdelegate estimate_fee(count, price, multiplier \\ Decimal.new("0.07")), to: Predictions

  @doc "See `ExKalshi.Predictions.market_summary/1`."
  defdelegate market_summary(market), to: Predictions
end
