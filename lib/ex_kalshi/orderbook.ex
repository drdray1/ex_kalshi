defmodule ExKalshi.Orderbook do
  @moduledoc """
  A parsed Kalshi orderbook.

  Kalshi books hold **bids only**: `yes` is the list of resting YES bids and
  `no` the list of resting NO bids, each as `{price, count}` `Decimal` pairs
  sorted best (highest) first. A YES bid at `p` is the same resting order as
  a NO ask at `1 - p`, so the best YES ask is `1 - best NO bid`.

  Builds from a REST `GET /markets/{ticker}/orderbook` response
  (`from_rest/2`), from a WebSocket `orderbook_snapshot` (`from_snapshot/1`),
  and stays current with `apply_delta/2`.
  """

  @type level :: {Decimal.t(), Decimal.t()}
  @type t :: %__MODULE__{
          ticker: String.t() | nil,
          yes: [level()],
          no: [level()],
          seq: non_neg_integer() | nil
        }

  defstruct ticker: nil, yes: [], no: [], seq: nil

  @doc "Builds a book from a REST orderbook response."
  @spec from_rest(map(), String.t() | nil) :: t()
  def from_rest(%{"orderbook_fp" => %{} = book}, ticker) do
    %__MODULE__{
      ticker: ticker,
      yes: parse_levels(book["yes_dollars"]),
      no: parse_levels(book["no_dollars"])
    }
  end

  def from_rest(_, ticker), do: %__MODULE__{ticker: ticker}

  @doc "Builds a book from the `msg` of a WebSocket `orderbook_snapshot`."
  @spec from_snapshot(map(), non_neg_integer() | nil) :: t()
  def from_snapshot(msg, seq \\ nil) do
    %__MODULE__{
      ticker: msg["market_ticker"],
      yes: parse_levels(msg["yes_dollars_fp"] || msg["yes_dollars"]),
      no: parse_levels(msg["no_dollars_fp"] || msg["no_dollars"]),
      seq: seq
    }
  end

  @doc """
  Applies an `orderbook_delta`: adds `delta` contracts at `price` on `side`,
  removing the level when it reaches zero.

      iex> book = %ExKalshi.Orderbook{yes: [{Decimal.new("0.50"), Decimal.new("10")}]}
      iex> ExKalshi.Orderbook.apply_delta(book, :yes, "0.50", "-10.00").yes
      []
  """
  @spec apply_delta(t(), :yes | :no | String.t(), term(), term(), non_neg_integer() | nil) :: t()
  def apply_delta(book, side, price, delta, seq \\ nil) do
    side = side_atom(side)
    price = dec(price)
    delta = dec(delta)

    levels =
      book
      |> Map.fetch!(side)
      |> update_level(price, delta)

    book
    |> Map.put(side, levels)
    |> Map.put(:seq, seq || book.seq)
  end

  @doc "Best (highest) YES bid as `{price, count}`, or `nil`."
  @spec best_yes_bid(t()) :: level() | nil
  def best_yes_bid(%__MODULE__{yes: [best | _]}), do: best
  def best_yes_bid(_), do: nil

  @doc "Best (highest) NO bid as `{price, count}`, or `nil`."
  @spec best_no_bid(t()) :: level() | nil
  def best_no_bid(%__MODULE__{no: [best | _]}), do: best
  def best_no_bid(_), do: nil

  @doc "Best YES ask price, i.e. `1 - best NO bid`, or `nil`."
  @spec best_yes_ask(t()) :: Decimal.t() | nil
  def best_yes_ask(book) do
    case best_no_bid(book) do
      {price, _} -> Decimal.sub(1, price)
      nil -> nil
    end
  end

  @doc "Best NO ask price, i.e. `1 - best YES bid`, or `nil`."
  @spec best_no_ask(t()) :: Decimal.t() | nil
  def best_no_ask(book) do
    case best_yes_bid(book) do
      {price, _} -> Decimal.sub(1, price)
      nil -> nil
    end
  end

  @doc "Total resting contracts on a side."
  @spec depth(t(), :yes | :no) :: Decimal.t()
  def depth(book, side) do
    book
    |> Map.fetch!(side)
    |> Enum.reduce(Decimal.new(0), fn {_, count}, acc -> Decimal.add(acc, count) end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp parse_levels(levels) when is_list(levels) do
    levels
    |> Enum.map(fn [price, count] -> {dec(price), dec(count)} end)
    |> Enum.reject(fn {_, count} -> Decimal.compare(count, 0) != :gt end)
    |> sort_levels()
  end

  defp parse_levels(_), do: []

  defp sort_levels(levels), do: Enum.sort_by(levels, fn {price, _} -> price end, {:desc, Decimal})

  defp update_level(levels, price, delta) do
    {found, rest} = Enum.split_with(levels, fn {p, _} -> Decimal.equal?(p, price) end)

    existing =
      case found do
        [{_, count} | _] -> count
        [] -> Decimal.new(0)
      end

    new_count = Decimal.add(existing, delta)

    if Decimal.compare(new_count, 0) == :gt,
      do: sort_levels([{price, new_count} | rest]),
      else: rest
  end

  defp side_atom(:yes), do: :yes
  defp side_atom(:no), do: :no
  defp side_atom("yes"), do: :yes
  defp side_atom("no"), do: :no

  defp dec(%Decimal{} = d), do: d
  defp dec(v) when is_binary(v), do: Decimal.new(v)
  defp dec(v) when is_integer(v), do: Decimal.new(v)
  defp dec(v) when is_float(v), do: Decimal.from_float(v)
end
