defmodule ExKalshi.Query do
  @moduledoc """
  Builds query strings for Kalshi Trade API requests.

  Whitelists keys, drops `nil` values, expands lists into repeated keys and
  returns a URL with the encoded query appended. Some Kalshi parameters
  (`tickers`, `event_tickers`) are comma-separated strings instead; pass a
  list through `csv/1` for those.
  """

  @doc """
  Appends the allowed, non-nil options from `opts` to `path` as a query string.

  ## Examples

      iex> ExKalshi.Query.url("/markets", [limit: 10, cursor: nil], [:limit, :cursor])
      "/markets?limit=10"

      iex> ExKalshi.Query.url("/markets", [], [:limit])
      "/markets"
  """
  @spec url(String.t(), keyword(), [atom()]) :: String.t()
  def url(path, opts, allowed_keys) do
    case encode(opts, allowed_keys) do
      "" -> path
      query -> path <> "?" <> query
    end
  end

  @doc """
  Encodes the allowed, non-nil options from `opts` into a query string.

      iex> ExKalshi.Query.encode([status: "open", limit: 5], [:status, :limit])
      "status=open&limit=5"
  """
  @spec encode(keyword(), [atom()]) :: String.t()
  def encode(opts, allowed_keys) do
    opts
    |> Enum.filter(fn {key, value} -> key in allowed_keys and not is_nil(value) end)
    |> Enum.flat_map(&expand/1)
    |> URI.encode_query()
  end

  @doc """
  Joins a list into Kalshi's comma-separated form; strings pass through.

      iex> ExKalshi.Query.csv(["A", "B"])
      "A,B"

      iex> ExKalshi.Query.csv("A,B")
      "A,B"

      iex> ExKalshi.Query.csv(nil)
      nil
  """
  @spec csv(nil | String.t() | [String.t()]) :: nil | String.t()
  def csv(nil), do: nil
  def csv(value) when is_binary(value), do: value
  def csv(values) when is_list(values), do: Enum.join(values, ",")

  defp expand({key, values}) when is_list(values) do
    Enum.map(values, fn value -> {Atom.to_string(key), to_string(value)} end)
  end

  defp expand({key, value}), do: [{Atom.to_string(key), to_string(value)}]
end
