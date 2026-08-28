defmodule ExKalshi.WebSocket do
  @moduledoc """
  Kalshi WebSocket protocol: command builders, event structs and parsing.

  This module holds no process state — see `ExKalshi.WebSocket.Connection`
  for the managed connection.

  ## Protocol

  Commands are JSON with a client-chosen, monotonically increasing `id`:

      {"id": 1, "cmd": "subscribe", "params": {"channels": ["ticker"], "market_tickers": ["T"]}}

  The server answers with `subscribed` (carrying a server `sid`), `ok` or
  `error`, and then streams data messages `{"type", "sid", "seq", "msg"}`.
  `seq` increments per subscription; a gap means messages were lost.

  ## Channels

  #{Enum.map_join(~w(orderbook_delta ticker trade fill user_orders market_positions market_lifecycle_v2 multivariate_market_lifecycle communications order_group_updates cfbenchmarks_value pyth_value), "\n", &"  - `#{&1}`")}

  `fill`, `user_orders`, `market_positions`, `communications` and
  `order_group_updates` need an authenticated connection. `orderbook_delta`
  also requires auth.
  """

  alias ExKalshi.{Client, Orderbook, Signature}

  @channels ~w(orderbook_delta ticker trade fill user_orders market_positions
    market_lifecycle_v2 multivariate_market_lifecycle communications
    order_group_updates cfbenchmarks_value pyth_value)
  @ws_sign_path "/trade-api/ws/v2"

  # ============================================================================
  # Event structs
  # ============================================================================

  defmodule SubscribedEvent do
    @moduledoc "Reply to a `subscribe` command."
    defstruct [:id, :sid, :channel]
    @type t :: %__MODULE__{id: integer(), sid: integer(), channel: String.t()}
  end

  defmodule OkEvent do
    @moduledoc "Reply to `unsubscribe` / `update_subscription`."
    defstruct [:id, :sid, :seq, :msg]

    @type t :: %__MODULE__{
            id: integer() | nil,
            sid: integer() | nil,
            seq: integer() | nil,
            msg: map() | nil
          }
  end

  defmodule ErrorEvent do
    @moduledoc "Error reply to a command."
    defstruct [:id, :code, :message]
    @type t :: %__MODULE__{id: integer() | nil, code: integer() | nil, message: String.t() | nil}
  end

  defmodule SubscriptionsEvent do
    @moduledoc "Reply to `list_subscriptions`."
    defstruct [:id, :subscriptions]
    @type t :: %__MODULE__{id: integer() | nil, subscriptions: [map()]}
  end

  defmodule OrderbookSnapshotEvent do
    @moduledoc "Full orderbook for one market (sent right after subscribing to `orderbook_delta`)."
    defstruct [:sid, :seq, :market_ticker, :market_id, :book]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer(),
            market_ticker: String.t(),
            market_id: String.t() | nil,
            book: Orderbook.t()
          }
  end

  defmodule OrderbookDeltaEvent do
    @moduledoc "One price-level change. `delta` is signed contracts."
    defstruct [
      :sid,
      :seq,
      :market_ticker,
      :market_id,
      :side,
      :price,
      :delta,
      :ts_ms,
      :client_order_id
    ]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer(),
            market_ticker: String.t(),
            market_id: String.t() | nil,
            side: :yes | :no,
            price: Decimal.t(),
            delta: Decimal.t(),
            ts_ms: integer() | nil,
            client_order_id: String.t() | nil
          }
  end

  defmodule TickerEvent do
    @moduledoc "Top-of-book / last-price update."
    defstruct [
      :sid,
      :seq,
      :market_ticker,
      :market_id,
      :price,
      :yes_bid,
      :yes_ask,
      :yes_bid_size,
      :yes_ask_size,
      :volume,
      :open_interest,
      :last_trade_size,
      :ts_ms,
      :raw
    ]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer() | nil,
            market_ticker: String.t(),
            market_id: String.t() | nil,
            price: Decimal.t() | nil,
            yes_bid: Decimal.t() | nil,
            yes_ask: Decimal.t() | nil,
            yes_bid_size: Decimal.t() | nil,
            yes_ask_size: Decimal.t() | nil,
            volume: Decimal.t() | nil,
            open_interest: Decimal.t() | nil,
            last_trade_size: Decimal.t() | nil,
            ts_ms: integer() | nil,
            raw: map()
          }
  end

  defmodule TradeEvent do
    @moduledoc "A public trade."
    defstruct [
      :sid,
      :seq,
      :market_ticker,
      :market_id,
      :trade_id,
      :yes_price,
      :no_price,
      :count,
      :taker_side,
      :ts_ms,
      :raw
    ]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer() | nil,
            market_ticker: String.t(),
            market_id: String.t() | nil,
            trade_id: String.t() | nil,
            yes_price: Decimal.t() | nil,
            no_price: Decimal.t() | nil,
            count: Decimal.t() | nil,
            taker_side: String.t() | nil,
            ts_ms: integer() | nil,
            raw: map()
          }
  end

  defmodule FillEvent do
    @moduledoc "One of your orders was (partially) filled."
    defstruct [
      :sid,
      :seq,
      :market_ticker,
      :trade_id,
      :order_id,
      :client_order_id,
      :side,
      :action,
      :yes_price,
      :count,
      :fee_cost,
      :is_taker,
      :post_position,
      :ts_ms,
      :subaccount,
      :raw
    ]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer() | nil,
            market_ticker: String.t(),
            trade_id: String.t() | nil,
            order_id: String.t() | nil,
            client_order_id: String.t() | nil,
            side: String.t() | nil,
            action: String.t() | nil,
            yes_price: Decimal.t() | nil,
            count: Decimal.t() | nil,
            fee_cost: Decimal.t() | nil,
            is_taker: boolean() | nil,
            post_position: Decimal.t() | nil,
            ts_ms: integer() | nil,
            subaccount: integer() | nil,
            raw: map()
          }
  end

  defmodule UserOrderEvent do
    @moduledoc "Lifecycle update for one of your orders."
    defstruct [
      :sid,
      :seq,
      :market_ticker,
      :order_id,
      :client_order_id,
      :status,
      :side,
      :yes_price,
      :count,
      :remaining_count,
      :fill_count,
      :ts_ms,
      :raw
    ]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer() | nil,
            market_ticker: String.t() | nil,
            order_id: String.t() | nil,
            client_order_id: String.t() | nil,
            status: String.t() | nil,
            side: String.t() | nil,
            yes_price: Decimal.t() | nil,
            count: Decimal.t() | nil,
            remaining_count: Decimal.t() | nil,
            fill_count: Decimal.t() | nil,
            ts_ms: integer() | nil,
            raw: map()
          }
  end

  defmodule MarketLifecycleEvent do
    @moduledoc "Market opened / closed / paused / settled etc."
    defstruct [:sid, :seq, :market_ticker, :event_type, :raw]

    @type t :: %__MODULE__{
            sid: integer(),
            seq: integer() | nil,
            market_ticker: String.t() | nil,
            event_type: String.t() | nil,
            raw: map()
          }
  end

  defmodule GenericEvent do
    @moduledoc "Any data message this library does not model specifically."
    defstruct [:type, :sid, :seq, :msg]

    @type t :: %__MODULE__{
            type: String.t(),
            sid: integer() | nil,
            seq: integer() | nil,
            msg: map() | nil
          }
  end

  @type event ::
          SubscribedEvent.t()
          | OkEvent.t()
          | ErrorEvent.t()
          | SubscriptionsEvent.t()
          | OrderbookSnapshotEvent.t()
          | OrderbookDeltaEvent.t()
          | TickerEvent.t()
          | TradeEvent.t()
          | FillEvent.t()
          | UserOrderEvent.t()
          | MarketLifecycleEvent.t()
          | GenericEvent.t()

  # ============================================================================
  # Commands
  # ============================================================================

  @doc "All channel names this library knows."
  @spec channels() :: [String.t()]
  def channels, do: @channels

  @doc """
  Normalises channels to strings and raises on unknown ones.

      iex> ExKalshi.WebSocket.validate_channels!([:ticker, "fill"])
      ["ticker", "fill"]
  """
  @spec validate_channels!([atom() | String.t()]) :: [String.t()]
  def validate_channels!(channels) when is_list(channels) do
    normalized = channels |> Enum.map(&to_string/1) |> Enum.uniq()

    case Enum.reject(normalized, &(&1 in @channels)) do
      [] -> normalized
      invalid -> raise ArgumentError, "invalid channels: #{inspect(invalid)}"
    end
  end

  @doc """
  Builds a `subscribe` command.

      iex> ExKalshi.WebSocket.subscribe(1, ["ticker"], ["T1", "T2"])
      %{"id" => 1, "cmd" => "subscribe", "params" => %{"channels" => ["ticker"], "market_tickers" => ["T1", "T2"]}}

      iex> ExKalshi.WebSocket.subscribe(2, [:fill], [])
      %{"id" => 2, "cmd" => "subscribe", "params" => %{"channels" => ["fill"]}}
  """
  @spec subscribe(integer(), [atom() | String.t()], [String.t()]) :: map()
  def subscribe(id, channels, market_tickers \\ []) do
    params = %{"channels" => Enum.map(channels, &to_string/1)}

    params =
      if market_tickers == [], do: params, else: Map.put(params, "market_tickers", market_tickers)

    %{"id" => id, "cmd" => "subscribe", "params" => params}
  end

  @doc "Builds an `unsubscribe` command for server subscription ids."
  @spec unsubscribe(integer(), [integer()]) :: map()
  def unsubscribe(id, sids) when is_list(sids) do
    %{"id" => id, "cmd" => "unsubscribe", "params" => %{"sids" => sids}}
  end

  @doc """
  Builds an `update_subscription` command. `action` is `"add_markets"`,
  `"delete_markets"` or `"get_snapshot"`.
  """
  @spec update_subscription(integer(), [integer()], [String.t()], String.t()) :: map()
  def update_subscription(id, sids, market_tickers, action) do
    %{
      "id" => id,
      "cmd" => "update_subscription",
      "params" => %{"sids" => sids, "market_tickers" => market_tickers, "action" => action}
    }
  end

  @doc "Builds a `list_subscriptions` command."
  @spec list_subscriptions(integer()) :: map()
  def list_subscriptions(id), do: %{"id" => id, "cmd" => "list_subscriptions"}

  @doc """
  Auth headers for the WebSocket handshake: signs `GET /trade-api/ws/v2`.
  Returns `{:ok, headers}` or `{:error, reason}` if the key is invalid.
  """
  @spec handshake_headers(String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def handshake_headers(key_id, private_key_pem) do
    with {:ok, key} <- Signature.parse_private_key(private_key_pem) do
      {:ok, Signature.headers(key_id, key, "GET", @ws_sign_path)}
    end
  end

  @doc "WebSocket URL (delegates to `ExKalshi.Client.websocket_url/1`)."
  @spec websocket_url(boolean()) :: String.t()
  def websocket_url(demo \\ false), do: Client.websocket_url(demo)

  # ============================================================================
  # Parsing
  # ============================================================================

  @doc """
  Parses a raw text frame into `{:ok, type, event}`.

  `type` is the message type as an atom (`:ticker`, `:fill`,
  `:orderbook_delta`, `:subscribed`, `:error`, …). Unknown data types are
  returned as `{:ok, :unknown, %GenericEvent{}}`; malformed JSON gives
  `{:error, :invalid_json}`.
  """
  @spec parse_message(binary()) :: {:ok, atom(), event()} | {:error, term()}
  def parse_message(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{"type" => _} = map} -> parse_map(map)
      {:ok, _} -> {:error, :missing_type}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc "Parses an already-decoded message map."
  @spec parse_map(map()) :: {:ok, atom(), event()} | {:error, term()}
  def parse_map(%{"type" => "subscribed"} = m) do
    msg = m["msg"] || %{}
    {:ok, :subscribed, %SubscribedEvent{id: m["id"], sid: msg["sid"], channel: msg["channel"]}}
  end

  def parse_map(%{"type" => "ok"} = m) do
    {:ok, :ok, %OkEvent{id: m["id"], sid: m["sid"], seq: m["seq"], msg: m["msg"]}}
  end

  def parse_map(%{"type" => "error"} = m) do
    msg = m["msg"] || %{}

    {:ok, :error,
     %ErrorEvent{id: m["id"], code: msg["code"], message: msg["msg"] || msg["message"]}}
  end

  def parse_map(%{"type" => "subscriptions"} = m) do
    msg = m["msg"] || %{}

    {:ok, :subscriptions,
     %SubscriptionsEvent{id: m["id"], subscriptions: msg["subscriptions"] || []}}
  end

  def parse_map(%{"type" => "orderbook_snapshot", "msg" => msg} = m) do
    event = %OrderbookSnapshotEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      market_id: msg["market_id"],
      book: Orderbook.from_snapshot(msg, m["seq"])
    }

    {:ok, :orderbook_snapshot, event}
  end

  def parse_map(%{"type" => "orderbook_delta", "msg" => msg} = m) do
    event = %OrderbookDeltaEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      market_id: msg["market_id"],
      side: side_atom(msg["side"]),
      price: dec(msg["price_dollars"]),
      delta: dec(msg["delta_fp"]),
      ts_ms: msg["ts_ms"],
      client_order_id: msg["client_order_id"]
    }

    {:ok, :orderbook_delta, event}
  end

  def parse_map(%{"type" => "ticker", "msg" => msg} = m) do
    event = %TickerEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      market_id: msg["market_id"],
      price: dec(msg["price_dollars"]),
      yes_bid: dec(msg["yes_bid_dollars"]),
      yes_ask: dec(msg["yes_ask_dollars"]),
      yes_bid_size: dec(msg["yes_bid_size_fp"]),
      yes_ask_size: dec(msg["yes_ask_size_fp"]),
      volume: dec(msg["volume_fp"]),
      open_interest: dec(msg["open_interest_fp"]),
      last_trade_size: dec(msg["last_trade_size_fp"]),
      ts_ms: msg["ts_ms"],
      raw: msg
    }

    {:ok, :ticker, event}
  end

  def parse_map(%{"type" => "trade", "msg" => msg} = m) do
    event = %TradeEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      market_id: msg["market_id"],
      trade_id: msg["trade_id"],
      yes_price: dec(msg["yes_price_dollars"]),
      no_price: dec(msg["no_price_dollars"]),
      count: dec(msg["count_fp"]),
      taker_side: msg["taker_side"] || msg["taker_outcome_side"],
      ts_ms: msg["ts_ms"],
      raw: msg
    }

    {:ok, :trade, event}
  end

  def parse_map(%{"type" => "fill", "msg" => msg} = m) do
    event = %FillEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      trade_id: msg["trade_id"],
      order_id: msg["order_id"],
      client_order_id: msg["client_order_id"],
      side: msg["side"],
      action: msg["action"],
      yes_price: dec(msg["yes_price_dollars"]),
      count: dec(msg["count_fp"]),
      fee_cost: dec(msg["fee_cost"]),
      is_taker: msg["is_taker"],
      post_position: dec(msg["post_position_fp"]),
      ts_ms: msg["ts_ms"],
      subaccount: msg["subaccount"],
      raw: msg
    }

    {:ok, :fill, event}
  end

  def parse_map(%{"type" => "user_order", "msg" => msg} = m), do: parse_user_order(m, msg)
  def parse_map(%{"type" => "user_orders", "msg" => msg} = m), do: parse_user_order(m, msg)

  def parse_map(%{"type" => type, "msg" => msg} = m)
      when type in ~w(market_lifecycle_v2 market_lifecycle) do
    event = %MarketLifecycleEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: msg["market_ticker"],
      event_type: msg["event_type"] || msg["type"],
      raw: msg
    }

    {:ok, :market_lifecycle, event}
  end

  def parse_map(%{"type" => type} = m) when is_binary(type) do
    {:ok, :unknown, %GenericEvent{type: type, sid: m["sid"], seq: m["seq"], msg: m["msg"]}}
  end

  def parse_map(_), do: {:error, :missing_type}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_user_order(m, msg) do
    order = msg["order"] || msg

    event = %UserOrderEvent{
      sid: m["sid"],
      seq: m["seq"],
      market_ticker: order["market_ticker"] || order["ticker"],
      order_id: order["order_id"],
      client_order_id: order["client_order_id"],
      status: order["status"],
      side: order["side"],
      yes_price: dec(order["yes_price_dollars"]),
      count: dec(order["initial_count_fp"] || order["count_fp"]),
      remaining_count: dec(order["remaining_count_fp"]),
      fill_count: dec(order["fill_count_fp"]),
      ts_ms: msg["ts_ms"] || order["ts_ms"],
      raw: msg
    }

    {:ok, :user_orders, event}
  end

  defp side_atom("yes"), do: :yes
  defp side_atom("no"), do: :no
  defp side_atom(_), do: nil

  defp dec(nil), do: nil
  defp dec(""), do: nil
  defp dec(v) when is_binary(v), do: Decimal.new(v)
  defp dec(v) when is_integer(v), do: Decimal.new(v)
  defp dec(v) when is_float(v), do: Decimal.from_float(v)
end
