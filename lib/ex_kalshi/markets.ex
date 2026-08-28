defmodule ExKalshi.Markets do
  @moduledoc """
  Kalshi Trade API - Markets, orderbooks, trades and candlesticks.

  Listing and reading markets is public. `get_orderbook/3` requires an
  authenticated client.

  Prices come back as fixed-point dollar strings (`"0.5600"`) in `*_dollars`
  fields and quantities as `*_fp` strings (`"10.00"`); the deprecated
  integer-cent fields are ignored by this library.
  """

  alias ExKalshi.{Client, Orderbook, Query}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @list_keys [
    :limit,
    :cursor,
    :event_ticker,
    :series_ticker,
    :status,
    :tickers,
    :min_created_ts,
    :max_created_ts,
    :min_updated_ts,
    :min_close_ts,
    :max_close_ts,
    :min_settled_ts,
    :max_settled_ts,
    :mve_filter
  ]
  @trades_keys [:limit, :cursor, :ticker, :min_ts, :max_ts, :is_block_trade]
  @candle_keys [:start_ts, :end_ts, :period_interval, :include_latest_before_start]
  @valid_periods [1, 60, 1440]
  @max_pages 50

  @doc """
  `GET /markets`

  ## Options

    - `:limit` - 1..1000 (default 100)
    - `:cursor` - pagination cursor from the previous response
    - `:event_ticker`, `:series_ticker` - filter by parent
    - `:status` - `"unopened" | "open" | "paused" | "closed" | "settled"`
    - `:tickers` - list or comma-separated string of market tickers
    - `:min_close_ts`, `:max_close_ts`, `:min_created_ts`, `:max_created_ts`,
      `:min_settled_ts`, `:max_settled_ts`, `:min_updated_ts` - Unix seconds
    - `:mve_filter` - `"only" | "exclude"` multivariate events

      iex> ExKalshi.Markets.list_markets(client, status: "open", limit: 5)
      {:ok, %{"markets" => [...], "cursor" => "..."}}
  """
  @spec list_markets(client(), keyword()) :: response()
  def list_markets(client, opts \\ []) do
    opts = Keyword.update(opts, :tickers, nil, &Query.csv/1)

    client
    |> Req.get(url: Query.url("/markets", opts, @list_keys))
    |> Client.handle_response()
  end

  @doc """
  Follows `cursor` until exhausted (or `#{@max_pages}` pages) and returns the
  concatenated market list.

      iex> ExKalshi.Markets.list_all_markets(client, series_ticker: "KXBTC15M")
      {:ok, [%{"ticker" => ...}, ...]}
  """
  @spec list_all_markets(client(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all_markets(client, opts \\ []) do
    fetch_pages(client, Keyword.delete(opts, :cursor), [], 0)
  end

  @doc "`GET /markets/{ticker}`"
  @spec get_market(client(), String.t()) :: response()
  def get_market(client, ticker) do
    client
    |> Req.get(url: "/markets/#{ticker}")
    |> Client.handle_response()
  end

  @doc """
  `GET /markets/{ticker}/orderbook` (authenticated).

  ## Options

    - `:depth` - number of levels per side; `0` (default) returns all

  The response holds bids only: `orderbook_fp.yes_dollars` and
  `orderbook_fp.no_dollars` as `[[price, count], ...]`. A YES bid at `p` is
  the same order as a NO ask at `1 - p`. Use `extract_orderbook/1` for a
  parsed `ExKalshi.Orderbook`.
  """
  @spec get_orderbook(client(), String.t(), keyword()) :: response()
  def get_orderbook(client, ticker, opts \\ []) do
    client
    |> Req.get(url: Query.url("/markets/#{ticker}/orderbook", opts, [:depth]))
    |> Client.handle_response()
  end

  @doc """
  `GET /markets/trades`

  ## Options

    - `:ticker`, `:limit`, `:cursor`, `:min_ts`, `:max_ts`, `:is_block_trade`
  """
  @spec list_trades(client(), keyword()) :: response()
  def list_trades(client, opts \\ []) do
    client
    |> Req.get(url: Query.url("/markets/trades", opts, @trades_keys))
    |> Client.handle_response()
  end

  @doc """
  `GET /series/{series_ticker}/markets/{ticker}/candlesticks`

  ## Options (required unless noted)

    - `:start_ts`, `:end_ts` - Unix seconds
    - `:period_interval` - minutes per candle: `1`, `60` or `1440`
    - `:include_latest_before_start` - optional boolean

      iex> ExKalshi.Markets.get_candlesticks(client, "KXBTC15M", "KXBTC15M-26AUG272300-00",
      ...>   start_ts: 1_756_000_000, end_ts: 1_756_100_000, period_interval: 1)
      {:ok, %{"candlesticks" => [...]}}
  """
  @spec get_candlesticks(client(), String.t(), String.t(), keyword()) :: response()
  def get_candlesticks(client, series_ticker, ticker, opts) do
    with :ok <- validate_candle_opts(opts) do
      path = "/series/#{series_ticker}/markets/#{ticker}/candlesticks"

      client
      |> Req.get(url: Query.url(path, opts, @candle_keys))
      |> Client.handle_response()
    end
  end

  @doc "Extracts the market list from a `list_markets/2` response."
  @spec extract_markets(map()) :: [map()]
  def extract_markets(%{"markets" => markets}) when is_list(markets), do: markets
  def extract_markets(_), do: []

  @doc "Extracts the single market from a `get_market/2` response."
  @spec extract_market(map()) :: map() | nil
  def extract_market(%{"market" => %{} = market}), do: market
  def extract_market(_), do: nil

  @doc "Extracts the pagination cursor; `nil` when there are no more pages."
  @spec extract_cursor(map()) :: String.t() | nil
  def extract_cursor(%{"cursor" => cursor}) when is_binary(cursor) and cursor != "", do: cursor
  def extract_cursor(_), do: nil

  @doc "Extracts the trade list from a `list_trades/2` response."
  @spec extract_trades(map()) :: [map()]
  def extract_trades(%{"trades" => trades}) when is_list(trades), do: trades
  def extract_trades(_), do: []

  @doc "Extracts the candlestick list from a `get_candlesticks/4` response."
  @spec extract_candlesticks(map()) :: [map()]
  def extract_candlesticks(%{"candlesticks" => candles}) when is_list(candles), do: candles
  def extract_candlesticks(_), do: []

  @doc "Parses a `get_orderbook/3` response into an `ExKalshi.Orderbook`."
  @spec extract_orderbook(map(), String.t() | nil) :: Orderbook.t()
  def extract_orderbook(response, ticker \\ nil), do: Orderbook.from_rest(response, ticker)

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp fetch_pages(_client, _opts, acc, @max_pages), do: {:ok, acc}

  defp fetch_pages(client, opts, acc, page) do
    case list_markets(client, opts) do
      {:ok, response} ->
        acc = acc ++ extract_markets(response)

        case extract_cursor(response) do
          nil -> {:ok, acc}
          cursor -> fetch_pages(client, Keyword.put(opts, :cursor, cursor), acc, page + 1)
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_candle_opts(opts) do
    missing = Enum.reject([:start_ts, :end_ts, :period_interval], &Keyword.has_key?(opts, &1))
    period = Keyword.get(opts, :period_interval)

    cond do
      missing != [] ->
        {:error, {:validation_error, ["missing required options: #{inspect(missing)}"]}}

      period not in @valid_periods ->
        {:error,
         {:validation_error, ["period_interval must be one of #{inspect(@valid_periods)}"]}}

      true ->
        :ok
    end
  end
end
