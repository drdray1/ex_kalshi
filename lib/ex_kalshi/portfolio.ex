defmodule ExKalshi.Portfolio do
  @moduledoc """
  Kalshi Trade API - Balance, positions, fills and settlements.

  All endpoints require an authenticated client. Amounts are fixed-point
  dollar strings (`balance_dollars`, `*_dollars`) and contract counts are
  `*_fp` strings; `position_fp` is signed — positive is a YES position,
  negative is NO.
  """

  alias ExKalshi.{Client, Query}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @balance_keys [:subaccount, :exchange_index]
  @positions_keys [
    :cursor,
    :limit,
    :count_filter,
    :ticker,
    :event_ticker,
    :subaccount,
    :exchange_index
  ]
  @fills_keys [
    :ticker,
    :order_id,
    :min_ts,
    :max_ts,
    :limit,
    :cursor,
    :subaccount,
    :exchange_index
  ]
  @settlements_keys [:limit, :cursor, :ticker, :event_ticker, :min_ts, :max_ts, :subaccount]

  @doc """
  `GET /portfolio/balance`

  ## Options

    - `:subaccount` - 0 (primary, default) .. 63
    - `:exchange_index` - restrict to one shard

      iex> ExKalshi.Portfolio.get_balance(client)
      {:ok, %{"balance_dollars" => "1234.5600", "portfolio_value" => 12345, ...}}
  """
  @spec get_balance(client(), keyword()) :: response()
  def get_balance(client, opts \\ []) do
    client
    |> Req.get(url: Query.url("/portfolio/balance", opts, @balance_keys))
    |> Client.handle_response()
  end

  @doc """
  `GET /portfolio/positions`

  ## Options

    - `:ticker`, `:event_ticker`, `:count_filter` (`"position" | "total_traded"`),
      `:limit` (1..1000), `:cursor`, `:subaccount`, `:exchange_index`
  """
  @spec list_positions(client(), keyword()) :: response()
  def list_positions(client, opts \\ []) do
    client
    |> Req.get(url: Query.url("/portfolio/positions", opts, @positions_keys))
    |> Client.handle_response()
  end

  @doc """
  `GET /portfolio/fills`

  ## Options

    - `:ticker`, `:order_id`, `:min_ts`, `:max_ts`, `:limit`, `:cursor`,
      `:subaccount`, `:exchange_index`
  """
  @spec list_fills(client(), keyword()) :: response()
  def list_fills(client, opts \\ []) do
    client
    |> Req.get(url: Query.url("/portfolio/fills", opts, @fills_keys))
    |> Client.handle_response()
  end

  @doc """
  `GET /portfolio/settlements`

  ## Options

    - `:ticker`, `:event_ticker`, `:min_ts`, `:max_ts`, `:limit`, `:cursor`, `:subaccount`
  """
  @spec list_settlements(client(), keyword()) :: response()
  def list_settlements(client, opts \\ []) do
    client
    |> Req.get(url: Query.url("/portfolio/settlements", opts, @settlements_keys))
    |> Client.handle_response()
  end

  @doc "`GET /portfolio/summary/total_resting_order_value`"
  @spec resting_order_value(client(), keyword()) :: response()
  def resting_order_value(client, opts \\ []) do
    client
    |> Req.get(
      url: Query.url("/portfolio/summary/total_resting_order_value", opts, [:subaccount])
    )
    |> Client.handle_response()
  end

  @doc """
  Available balance as a `Decimal`, from the `balance_dollars` field
  (falls back to integer cents in `balance`).

      iex> ExKalshi.Portfolio.available_balance(%{"balance_dollars" => "12.3400"})
      Decimal.new("12.3400")
  """
  @spec available_balance(map()) :: Decimal.t()
  def available_balance(%{"balance_dollars" => dollars}) when is_binary(dollars),
    do: Decimal.new(dollars)

  def available_balance(%{"balance" => cents}) when is_integer(cents),
    do: cents |> Decimal.new() |> Decimal.div(100)

  def available_balance(_), do: Decimal.new(0)

  @doc "Extracts `market_positions` from a `list_positions/2` response."
  @spec extract_market_positions(map()) :: [map()]
  def extract_market_positions(%{"market_positions" => positions}) when is_list(positions),
    do: positions

  def extract_market_positions(_), do: []

  @doc "Extracts `event_positions` from a `list_positions/2` response."
  @spec extract_event_positions(map()) :: [map()]
  def extract_event_positions(%{"event_positions" => positions}) when is_list(positions),
    do: positions

  def extract_event_positions(_), do: []

  @doc "Extracts the fill list from a `list_fills/2` response."
  @spec extract_fills(map()) :: [map()]
  def extract_fills(%{"fills" => fills}) when is_list(fills), do: fills
  def extract_fills(_), do: []

  @doc "Extracts the settlement list from a `list_settlements/2` response."
  @spec extract_settlements(map()) :: [map()]
  def extract_settlements(%{"settlements" => settlements}) when is_list(settlements),
    do: settlements

  def extract_settlements(_), do: []

  @doc "Finds the market position for `ticker`, or `nil`."
  @spec find_position(map() | [map()], String.t()) :: map() | nil
  def find_position(%{} = response, ticker),
    do: response |> extract_market_positions() |> find_position(ticker)

  def find_position(positions, ticker) when is_list(positions),
    do: Enum.find(positions, &(&1["ticker"] == ticker))
end
