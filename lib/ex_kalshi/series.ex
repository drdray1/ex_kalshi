defmodule ExKalshi.Series do
  @moduledoc """
  Kalshi Trade API - Series (a recurring template of events, e.g. `KXBTC15M`).

  Public endpoints. The series carries `fee_type` and `fee_multiplier`, which
  `ExKalshi.Predictions.estimate_fee/3` needs for exact fees.
  """

  alias ExKalshi.{Client, Query}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @list_keys [:category, :tags, :include_product_metadata, :include_volume, :min_updated_ts]

  @doc """
  `GET /series`

  ## Options

    - `:category`, `:tags` (comma-separated), `:include_product_metadata`,
      `:include_volume`, `:min_updated_ts`
  """
  @spec list_series(client(), keyword()) :: response()
  def list_series(client, opts \\ []) do
    opts = Keyword.update(opts, :tags, nil, &Query.csv/1)

    client
    |> Req.get(url: Query.url("/series", opts, @list_keys))
    |> Client.handle_response()
  end

  @doc "`GET /series/{series_ticker}`"
  @spec get_series(client(), String.t()) :: response()
  def get_series(client, series_ticker) do
    client
    |> Req.get(url: "/series/#{series_ticker}")
    |> Client.handle_response()
  end

  @doc "Extracts the series list from a `list_series/2` response."
  @spec extract_series_list(map()) :: [map()]
  def extract_series_list(%{"series" => series}) when is_list(series), do: series
  def extract_series_list(_), do: []

  @doc "Extracts the series from a `get_series/2` response."
  @spec extract_series(map()) :: map() | nil
  def extract_series(%{"series" => %{} = series}), do: series
  def extract_series(_), do: nil
end
