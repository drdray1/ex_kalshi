defmodule ExKalshi.Predictions do
  @moduledoc """
  Prediction-market ergonomics on top of the raw Kalshi endpoints.

  Kalshi quotes every order on the YES leg. This module lets you think in
  YES/NO terms and does the conversion:

  | You want | Wire order |
  |---|---|
  | buy YES @ p | `bid` @ p |
  | sell YES @ p | `ask` @ p |
  | buy NO @ p | `ask` @ 1 − p |
  | sell NO @ p | `bid` @ 1 − p |

  Every price is a probability in dollars (`0.01`–`0.99`); a contract pays
  `$1.00` if it settles in your favour. All arithmetic uses `Decimal`.

  ## Fees

  Kalshi's standard fee is quadratic in price:
  `fee = ceil_to_cent(multiplier × count × p × (1 − p))` with a default
  multiplier of `0.07`. Series can override the multiplier (`fee_multiplier`
  on `ExKalshi.Series.get_series/2`), so pass it when you have it.
  """

  alias ExKalshi.{Orderbook, Orders}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}
  @type price :: number() | Decimal.t() | String.t()

  @default_fee_multiplier Decimal.new("0.07")
  @coinbase_suffix "-KALSHI"

  # ============================================================================
  # Trading
  # ============================================================================

  @doc """
  Buys YES contracts: `bid` at `price`.

  ## Options

  Any `ExKalshi.Orders.create_order/2` param: `:time_in_force`
  (default `"good_till_canceled"`), `:client_order_id`, `:reduce_only`,
  `:post_only`, `:expiration_time`, `:self_trade_prevention_type`, …

      iex> ExKalshi.Predictions.buy_yes(client, "KXBTC15M-26AUG272300-00", 10, 0.56,
      ...>   client_order_id: "abc")
      {:ok, %{"order_id" => ...}}
  """
  @spec buy_yes(client(), String.t(), price(), price(), keyword()) :: response()
  def buy_yes(client, ticker, count, price, opts \\ []),
    do: place(client, ticker, "bid", count, price, opts)

  @doc "Sells YES contracts: `ask` at `price`. Same options as `buy_yes/5`."
  @spec sell_yes(client(), String.t(), price(), price(), keyword()) :: response()
  def sell_yes(client, ticker, count, price, opts \\ []),
    do: place(client, ticker, "ask", count, price, opts)

  @doc "Buys NO contracts at NO price `price`: `ask` YES at `1 - price`."
  @spec buy_no(client(), String.t(), price(), price(), keyword()) :: response()
  def buy_no(client, ticker, count, price, opts \\ []),
    do: place(client, ticker, "ask", count, no_to_yes_price(price), opts)

  @doc "Sells NO contracts at NO price `price`: `bid` YES at `1 - price`."
  @spec sell_no(client(), String.t(), price(), price(), keyword()) :: response()
  def sell_no(client, ticker, count, price, opts \\ []),
    do: place(client, ticker, "bid", count, no_to_yes_price(price), opts)

  @doc """
  Builds (without sending) the `create_order/2` params for a YES/NO order.

      iex> ExKalshi.Predictions.order_params("T", :buy, :no, 5, 0.30)
      %{ticker: "T", side: "ask", count: 5, price: Decimal.new("0.70")}
  """
  @spec order_params(String.t(), :buy | :sell, :yes | :no, price(), price(), keyword()) :: map()
  def order_params(ticker, action, outcome, count, price, opts \\ []) do
    {side, wire_price} =
      case {action, outcome} do
        {:buy, :yes} -> {"bid", dec(price)}
        {:sell, :yes} -> {"ask", dec(price)}
        {:buy, :no} -> {"ask", no_to_yes_price(price)}
        {:sell, :no} -> {"bid", no_to_yes_price(price)}
      end

    opts
    |> Map.new()
    |> Map.merge(%{ticker: ticker, side: side, count: count, price: wire_price})
  end

  # ============================================================================
  # Price math
  # ============================================================================

  @doc """
  Converts a NO price to the equivalent YES price (`1 - p`), and vice versa.

      iex> ExKalshi.Predictions.no_to_yes_price("0.30")
      Decimal.new("0.70")
  """
  @spec no_to_yes_price(price()) :: Decimal.t()
  def no_to_yes_price(price), do: Decimal.sub(1, dec(price))

  @doc "Alias of `no_to_yes_price/1` — the conversion is symmetric."
  @spec yes_to_no_price(price()) :: Decimal.t()
  def yes_to_no_price(price), do: no_to_yes_price(price)

  @doc """
  Implied probability (0–1) of a YES price. Prices are already
  probabilities in dollars, so this is the identity as a `Decimal`.
  """
  @spec implied_probability(price()) :: Decimal.t()
  def implied_probability(price), do: dec(price)

  @doc """
  Quadratic Kalshi fee, rounded **up** to the cent.

      iex> ExKalshi.Predictions.estimate_fee(100, 0.50)
      Decimal.new("1.75")
      iex> ExKalshi.Predictions.estimate_fee(1, 0.50)
      Decimal.new("0.02")
  """
  @spec estimate_fee(price(), price(), price()) :: Decimal.t()
  def estimate_fee(count, price, multiplier \\ @default_fee_multiplier) do
    p = dec(price)

    dec(multiplier)
    |> Decimal.mult(dec(count))
    |> Decimal.mult(p)
    |> Decimal.mult(Decimal.sub(1, p))
    |> Decimal.round(2, :ceiling)
  end

  @doc "Cost to open `count` contracts at `price` (before fees)."
  @spec cost(price(), price()) :: Decimal.t()
  def cost(count, price), do: Decimal.mult(dec(count), dec(price))

  @doc "Payout if `count` contracts settle in your favour: `count × $1`."
  @spec max_payout(price()) :: Decimal.t()
  def max_payout(count), do: dec(count)

  @doc "Profit if the position wins: `count × (1 − price)`."
  @spec max_profit(price(), price()) :: Decimal.t()
  def max_profit(count, price), do: Decimal.mult(dec(count), Decimal.sub(1, dec(price)))

  # ============================================================================
  # Orderbook helpers
  # ============================================================================

  @doc "Best YES bid price from a book, or `nil`."
  @spec best_yes_bid(Orderbook.t()) :: Decimal.t() | nil
  def best_yes_bid(book), do: book |> Orderbook.best_yes_bid() |> level_price()

  @doc "Best YES ask price from a book (`1 − best NO bid`), or `nil`."
  @spec best_yes_ask(Orderbook.t()) :: Decimal.t() | nil
  def best_yes_ask(book), do: Orderbook.best_yes_ask(book)

  @doc "Best NO bid price from a book, or `nil`."
  @spec best_no_bid(Orderbook.t()) :: Decimal.t() | nil
  def best_no_bid(book), do: book |> Orderbook.best_no_bid() |> level_price()

  @doc "Best NO ask price from a book (`1 − best YES bid`), or `nil`."
  @spec best_no_ask(Orderbook.t()) :: Decimal.t() | nil
  def best_no_ask(book), do: Orderbook.best_no_ask(book)

  @doc "YES mid price `(bid + ask) / 2`, or `nil` when either side is empty."
  @spec mid_price(Orderbook.t()) :: Decimal.t() | nil
  def mid_price(book) do
    with bid when not is_nil(bid) <- best_yes_bid(book),
         ask when not is_nil(ask) <- best_yes_ask(book) do
      bid |> Decimal.add(ask) |> Decimal.div(2)
    end
  end

  @doc "YES spread `ask − bid`, or `nil` when either side is empty."
  @spec spread(Orderbook.t()) :: Decimal.t() | nil
  def spread(book) do
    with bid when not is_nil(bid) <- best_yes_bid(book),
         ask when not is_nil(ask) <- best_yes_ask(book) do
      Decimal.sub(ask, bid)
    end
  end

  # ============================================================================
  # Positions & markets
  # ============================================================================

  @doc """
  Which way a market position points, from its signed `position_fp`.

      iex> ExKalshi.Predictions.position_side(%{"position_fp" => "-5.00"})
      :no
  """
  @spec position_side(map() | price()) :: :yes | :no | :flat
  def position_side(%{"position_fp" => fp}), do: position_side(fp)
  def position_side(%{"position" => n}) when is_integer(n), do: position_side(n)
  def position_side(%{}), do: :flat

  def position_side(value) do
    case Decimal.compare(dec(value), 0) do
      :gt -> :yes
      :lt -> :no
      :eq -> :flat
    end
  end

  @doc "Absolute contract count of a market position as a `Decimal`."
  @spec position_count(map()) :: Decimal.t()
  def position_count(%{"position_fp" => fp}), do: fp |> dec() |> Decimal.abs()

  def position_count(%{"position" => n}) when is_integer(n),
    do: n |> Decimal.new() |> Decimal.abs()

  def position_count(_), do: Decimal.new(0)

  @doc """
  Condenses a market map into the fields you look at when trading.

  Returns `%{ticker, title, status, yes_bid, yes_ask, no_bid, no_ask, last_price,
  volume, open_interest, close_time, result}` with `Decimal` prices.
  """
  @spec market_summary(map()) :: map()
  def market_summary(market) when is_map(market) do
    %{
      ticker: market["ticker"],
      event_ticker: market["event_ticker"],
      title: market["title"] || market["yes_sub_title"],
      status: market["status"],
      yes_bid: dec_or_nil(market["yes_bid_dollars"]),
      yes_ask: dec_or_nil(market["yes_ask_dollars"]),
      no_bid: dec_or_nil(market["no_bid_dollars"]),
      no_ask: dec_or_nil(market["no_ask_dollars"]),
      last_price: dec_or_nil(market["last_price_dollars"]),
      volume: dec_or_nil(market["volume_fp"]),
      open_interest: dec_or_nil(market["open_interest_fp"]),
      close_time: market["close_time"],
      result: market["result"]
    }
  end

  @doc "True when a market is open for trading."
  @spec tradable?(map()) :: boolean()
  def tradable?(%{"status" => "open"}), do: true
  def tradable?(_), do: false

  # ============================================================================
  # Coinbase bridge
  # ============================================================================

  @doc """
  Coinbase lists Kalshi contracts as `<ticker>-KALSHI` product IDs.

      iex> ExKalshi.Predictions.to_coinbase_product_id("KXBTC15M-26AUG272300-00")
      "KXBTC15M-26AUG272300-00-KALSHI"
  """
  @spec to_coinbase_product_id(String.t()) :: String.t()
  def to_coinbase_product_id(ticker) do
    if String.ends_with?(ticker, @coinbase_suffix), do: ticker, else: ticker <> @coinbase_suffix
  end

  @doc """
  Strips the Coinbase `-KALSHI` suffix.

      iex> ExKalshi.Predictions.from_coinbase_product_id("KXBTC15M-26AUG272300-00-KALSHI")
      "KXBTC15M-26AUG272300-00"
  """
  @spec from_coinbase_product_id(String.t()) :: String.t()
  def from_coinbase_product_id(product_id),
    do: String.replace_suffix(product_id, @coinbase_suffix, "")

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp place(client, ticker, side, count, price, opts) do
    params =
      opts
      |> Map.new()
      |> Map.merge(%{ticker: ticker, side: side, count: count, price: price})

    Orders.create_order(client, params)
  end

  defp level_price({price, _count}), do: price
  defp level_price(nil), do: nil

  defp dec(%Decimal{} = d), do: d
  defp dec(v) when is_binary(v), do: Decimal.new(v)
  defp dec(v) when is_integer(v), do: Decimal.new(v)
  defp dec(v) when is_float(v), do: Decimal.from_float(v)

  defp dec_or_nil(nil), do: nil
  defp dec_or_nil(""), do: nil
  defp dec_or_nil(v), do: dec(v)
end
