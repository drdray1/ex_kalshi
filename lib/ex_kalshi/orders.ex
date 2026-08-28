defmodule ExKalshi.Orders do
  @moduledoc """
  Kalshi Trade API - Orders (V2 endpoints under `/portfolio/events/orders`).

  Every order is expressed on the **YES leg**: `side: "bid"` buys YES,
  `side: "ask"` sells YES. Buying NO at price `p` is the same order as
  selling YES at `1 - p` — `ExKalshi.Predictions` does that conversion for
  you.

  Prices are fixed-point dollar strings with 2–4 decimals (`"0.5600"`),
  counts are contract quantities with up to 2 decimals (`"10.00"`).
  `format_price/1` and `format_count/1` accept numbers, `Decimal`s or strings.

  Write requests are sent with HTTP retries disabled: a timeout after the
  exchange accepted an order must not be replayed. Use `client_order_id` and
  `list_orders/2` to resolve ambiguous failures.
  """

  alias ExKalshi.{Client, Query}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}
  @type order_params :: map() | keyword()

  @sides ~w(bid ask)
  @time_in_force ~w(good_till_canceled immediate_or_cancel fill_or_kill)
  @stp_types ~w(taker_at_cross maker)
  @default_tif "good_till_canceled"
  @default_stp "taker_at_cross"

  @order_fields ~w(ticker side count price time_in_force self_trade_prevention_type
    client_order_id expiration_time post_only reduce_only cancel_order_on_pause
    subaccount order_group_id exchange_index)a

  @list_keys [
    :ticker,
    :event_ticker,
    :min_ts,
    :max_ts,
    :status,
    :limit,
    :cursor,
    :subaccount,
    :exchange_index
  ]
  @cancel_keys [:subaccount, :exchange_index, :market_ticker]

  @doc """
  `POST /portfolio/events/orders`

  ## Params (map or keyword)

    - `:ticker` - market ticker (required)
    - `:side` - `"bid"` (buy YES) or `"ask"` (sell YES) (required)
    - `:count` - contracts, e.g. `10` / `"10.00"` (required)
    - `:price` - YES price in dollars, e.g. `0.56` / `"0.5600"` (required)
    - `:time_in_force` - `"good_till_canceled"` (default), `"immediate_or_cancel"`,
      `"fill_or_kill"`
    - `:self_trade_prevention_type` - `"taker_at_cross"` (default) or `"maker"`
    - `:client_order_id`, `:expiration_time` (Unix seconds, GTC only),
      `:post_only`, `:reduce_only`, `:cancel_order_on_pause`, `:subaccount`,
      `:order_group_id`, `:exchange_index`

  Returns `{:ok, %{"order_id" => ..., "fill_count" => ..., "remaining_count" => ...}}`
  or `{:error, {:validation_error, messages}}` before anything is sent.

      iex> ExKalshi.Orders.create_order(client, ticker: "KXBTC15M-26AUG272300-00",
      ...>   side: "bid", count: 10, price: 0.56, client_order_id: "my-id")
      {:ok, %{"order_id" => "…", "client_order_id" => "my-id", ...}}
  """
  @spec create_order(client(), order_params()) :: response()
  def create_order(client, params) do
    with {:ok, body} <- build_order(params) do
      client
      |> Req.post(url: "/portfolio/events/orders", json: body, retry: false)
      |> Client.handle_response()
    end
  end

  @doc """
  `POST /portfolio/events/orders/batched` — up to a tier-dependent number of
  orders in one call. Each element takes the same params as `create_order/2`.
  Per-order failures come back inside `orders[].error` with a 201.
  """
  @spec batch_create_orders(client(), [order_params()]) :: response()
  def batch_create_orders(client, orders) when is_list(orders) do
    with {:ok, bodies} <- build_orders(orders) do
      client
      |> Req.post(url: "/portfolio/events/orders/batched", json: %{orders: bodies}, retry: false)
      |> Client.handle_response()
    end
  end

  @doc """
  `DELETE /portfolio/events/orders/{order_id}`

  ## Options

    - `:subaccount`, `:exchange_index`, `:market_ticker` (for shard routing)

  Returns `{:ok, %{"order_id" => ..., "reduced_by" => "10.00", ...}}`.
  """
  @spec cancel_order(client(), String.t(), keyword()) :: response()
  def cancel_order(client, order_id, opts \\ []) do
    client
    |> Req.delete(
      url: Query.url("/portfolio/events/orders/#{order_id}", opts, @cancel_keys),
      retry: false
    )
    |> Client.handle_response()
  end

  @doc """
  `DELETE /portfolio/events/orders/batched` with `{"order_ids": [...]}`.
  """
  @spec batch_cancel_orders(client(), [String.t()]) :: response()
  def batch_cancel_orders(client, order_ids) when is_list(order_ids) do
    client
    |> Req.delete(
      url: "/portfolio/events/orders/batched",
      json: %{order_ids: order_ids},
      retry: false
    )
    |> Client.handle_response()
  end

  @doc """
  `POST /portfolio/events/orders/{order_id}/amend`

  ## Params

    - `:ticker`, `:side`, `:price`, `:count` (required — the new total count)
    - `:client_order_id` (the original), `:updated_client_order_id`, `:exchange_index`
  """
  @spec amend_order(client(), String.t(), order_params()) :: response()
  def amend_order(client, order_id, params) do
    with {:ok, body} <- build_amend(params) do
      client
      |> Req.post(url: "/portfolio/events/orders/#{order_id}/amend", json: body, retry: false)
      |> Client.handle_response()
    end
  end

  @doc """
  `POST /portfolio/events/orders/{order_id}/decrease`

  ## Params

    - `:reduce_by` or `:reduce_to` - contract count (one required)
    - `:ticker`, `:exchange_index` - optional routing hints
  """
  @spec decrease_order(client(), String.t(), order_params()) :: response()
  def decrease_order(client, order_id, params) do
    with {:ok, body} <- build_decrease(params) do
      client
      |> Req.post(url: "/portfolio/events/orders/#{order_id}/decrease", json: body, retry: false)
      |> Client.handle_response()
    end
  end

  @doc """
  `GET /portfolio/orders`

  ## Options

    - `:ticker`, `:event_ticker`, `:status` (`"resting" | "canceled" | "executed"`),
      `:min_ts`, `:max_ts`, `:limit` (1..1000), `:cursor`, `:subaccount`, `:exchange_index`
  """
  @spec list_orders(client(), keyword()) :: response()
  def list_orders(client, opts \\ []) do
    opts = Keyword.update(opts, :event_ticker, nil, &Query.csv/1)

    client
    |> Req.get(url: Query.url("/portfolio/orders", opts, @list_keys))
    |> Client.handle_response()
  end

  @doc "`GET /portfolio/orders/{order_id}`"
  @spec get_order(client(), String.t()) :: response()
  def get_order(client, order_id) do
    client
    |> Req.get(url: "/portfolio/orders/#{order_id}")
    |> Client.handle_response()
  end

  @doc """
  Finds an order by `client_order_id`, scanning `list_orders/2` with the given
  filters. Returns `{:ok, order}`, `{:ok, nil}` when absent, or an error.
  Useful for resolving an ambiguous transport failure after `create_order/2`.
  """
  @spec find_by_client_order_id(client(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def find_by_client_order_id(client, client_order_id, opts \\ []) do
    case list_orders(client, opts) do
      {:ok, response} ->
        {:ok, Enum.find(extract_orders(response), &(&1["client_order_id"] == client_order_id))}

      {:error, _} = error ->
        error
    end
  end

  @doc "Extracts the order list from a `list_orders/2` response."
  @spec extract_orders(map()) :: [map()]
  def extract_orders(%{"orders" => orders}) when is_list(orders), do: orders
  def extract_orders(_), do: []

  @doc "Extracts the order from a `get_order/2` response."
  @spec extract_order(map()) :: map() | nil
  def extract_order(%{"order" => %{} = order}), do: order
  def extract_order(_), do: nil

  @doc """
  Formats a price as a 4-decimal dollar string.

      iex> ExKalshi.Orders.format_price(0.56)
      "0.5600"
      iex> ExKalshi.Orders.format_price(Decimal.new("0.5"))
      "0.5000"
      iex> ExKalshi.Orders.format_price("0.56")
      "0.5600"
  """
  @spec format_price(number() | Decimal.t() | String.t()) :: String.t()
  def format_price(value),
    do: value |> to_decimal() |> Decimal.round(4) |> Decimal.to_string(:normal)

  @doc """
  Formats a contract count as a 2-decimal string.

      iex> ExKalshi.Orders.format_count(10)
      "10.00"
  """
  @spec format_count(number() | Decimal.t() | String.t()) :: String.t()
  def format_count(value),
    do: value |> to_decimal() |> Decimal.round(2) |> Decimal.to_string(:normal)

  @doc "Valid `side` values."
  @spec sides() :: [String.t()]
  def sides, do: @sides

  @doc "Valid `time_in_force` values."
  @spec time_in_force_values() :: [String.t()]
  def time_in_force_values, do: @time_in_force

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_orders(orders) do
    orders
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {params, index}, {:ok, acc} ->
      case build_order(params) do
        {:ok, body} ->
          {:cont, {:ok, acc ++ [body]}}

        {:error, {:validation_error, msgs}} ->
          {:halt, {:error, {:validation_error, Enum.map(msgs, &"orders[#{index}]: #{&1}")}}}
      end
    end)
  end

  defp build_order(params) do
    params =
      params
      |> Map.new()
      |> Map.put_new(:time_in_force, @default_tif)
      |> Map.put_new(:self_trade_prevention_type, @default_stp)

    errors =
      []
      |> require_present(params, :ticker)
      |> require_enum(params, :side, @sides)
      |> require_fixed_point(params, :count)
      |> require_price(params, :price)
      |> require_enum(params, :time_in_force, @time_in_force)
      |> require_enum(params, :self_trade_prevention_type, @stp_types)
      |> check_ioc_expiration(params)

    case errors do
      [] -> {:ok, params |> Map.take(@order_fields) |> encode_amounts() |> stringify()}
      errors -> {:error, {:validation_error, Enum.reverse(errors)}}
    end
  end

  defp build_amend(params) do
    params = Map.new(params)

    errors =
      []
      |> require_present(params, :ticker)
      |> require_enum(params, :side, @sides)
      |> require_fixed_point(params, :count)
      |> require_price(params, :price)

    case errors do
      [] ->
        body =
          params
          |> Map.take([
            :ticker,
            :side,
            :price,
            :count,
            :client_order_id,
            :updated_client_order_id,
            :exchange_index
          ])
          |> encode_amounts()
          |> stringify()

        {:ok, body}

      errors ->
        {:error, {:validation_error, Enum.reverse(errors)}}
    end
  end

  defp build_decrease(params) do
    params = Map.new(params)

    cond do
      Map.has_key?(params, :reduce_by) ->
        {:ok,
         params
         |> Map.take([:reduce_by, :ticker, :exchange_index])
         |> Map.update!(:reduce_by, &format_count/1)
         |> stringify()}

      Map.has_key?(params, :reduce_to) ->
        {:ok,
         params
         |> Map.take([:reduce_to, :ticker, :exchange_index])
         |> Map.update!(:reduce_to, &format_count/1)
         |> stringify()}

      true ->
        {:error, {:validation_error, ["reduce_by or reduce_to is required"]}}
    end
  end

  defp require_present(errors, params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> errors
      _ -> ["#{key} is required" | errors]
    end
  end

  defp require_enum(errors, params, key, allowed) do
    value = params |> Map.get(key) |> to_string()

    if value in allowed,
      do: errors,
      else: ["#{key} must be one of #{inspect(allowed)}" | errors]
  end

  defp require_fixed_point(errors, params, key) do
    case to_decimal_safe(Map.get(params, key)) do
      {:ok, dec} ->
        if Decimal.compare(dec, 0) == :gt, do: errors, else: ["#{key} must be positive" | errors]

      :error ->
        ["#{key} must be a number" | errors]
    end
  end

  defp require_price(errors, params, key) do
    case to_decimal_safe(Map.get(params, key)) do
      {:ok, dec} ->
        if Decimal.compare(dec, 0) == :gt and Decimal.compare(dec, 1) == :lt,
          do: errors,
          else: ["#{key} must be between 0 and 1 exclusive" | errors]

      :error ->
        ["#{key} must be a number" | errors]
    end
  end

  defp check_ioc_expiration(errors, %{time_in_force: "immediate_or_cancel", expiration_time: exp})
       when not is_nil(exp),
       do: ["expiration_time cannot be combined with immediate_or_cancel" | errors]

  defp check_ioc_expiration(errors, _params), do: errors

  defp encode_amounts(params) do
    params
    |> Map.update(:count, nil, &format_count/1)
    |> Map.update(:price, nil, &format_price/1)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify(params), do: Map.new(params, fn {k, v} -> {to_string(k), v} end)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp to_decimal_safe(nil), do: :error

  defp to_decimal_safe(value) when is_binary(value) do
    case Decimal.parse(value) do
      {dec, ""} -> {:ok, dec}
      _ -> :error
    end
  end

  defp to_decimal_safe(value) when is_number(value) or is_struct(value, Decimal),
    do: {:ok, to_decimal(value)}

  defp to_decimal_safe(_), do: :error
end
