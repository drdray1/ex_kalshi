defmodule ExKalshi.OrderbookTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Orderbook}

  doctest ExKalshi.Orderbook

  defp d(v), do: Decimal.new(v)

  test "from_rest/2 sorts best first and keeps Decimals" do
    book = Orderbook.from_rest(Fixtures.orderbook_response(), "T")
    assert book.ticker == "T"
    assert [{p1, c1}, {p2, _}] = book.yes
    assert Decimal.equal?(p1, "0.55") and Decimal.equal?(c1, 100) and Decimal.equal?(p2, "0.54")
    assert {no_best, _} = Orderbook.best_no_bid(book)
    assert Decimal.equal?(no_best, "0.43")
  end

  test "from_rest/2 with an empty/malformed response" do
    assert %Orderbook{yes: [], no: [], ticker: "T"} = Orderbook.from_rest(%{}, "T")

    assert %Orderbook{yes: []} =
             Orderbook.from_rest(%{"orderbook_fp" => %{"yes_dollars" => nil}}, nil)
  end

  test "from_snapshot/2 uses *_fp keys and sorts" do
    book = Orderbook.from_snapshot(Fixtures.ws_orderbook_snapshot()["msg"], 9)
    assert book.seq == 9
    assert book.ticker == "KXBTC15M-26AUG272300-00"
    assert [{p, _} | _] = book.yes
    assert Decimal.equal?(p, "0.22")
  end

  test "derived prices" do
    book = Orderbook.from_rest(Fixtures.orderbook_response(), "T")
    assert Decimal.equal?(Orderbook.best_yes_ask(book), "0.57")
    assert Decimal.equal?(Orderbook.best_no_ask(book), "0.45")
    assert Decimal.equal?(Orderbook.depth(book, :yes), 350)
    assert Orderbook.best_yes_bid(%Orderbook{}) == nil
    assert Orderbook.best_yes_ask(%Orderbook{}) == nil
    assert Orderbook.best_no_ask(%Orderbook{}) == nil
  end

  describe "apply_delta/5" do
    setup do
      {:ok, book: Orderbook.from_rest(Fixtures.orderbook_response(), "T")}
    end

    test "adds to an existing level", %{book: book} do
      book = Orderbook.apply_delta(book, "yes", "0.5500", "25.00", 3)
      assert [{_, count} | _] = book.yes
      assert Decimal.equal?(count, 125)
      assert book.seq == 3
    end

    test "removes a level at zero and below", %{book: book} do
      book = Orderbook.apply_delta(book, :yes, "0.55", "-100")
      assert [{p, _}] = book.yes
      assert Decimal.equal?(p, "0.54")

      book = Orderbook.apply_delta(book, :yes, d("0.54"), -999)
      assert book.yes == []
    end

    test "inserts a new level in sorted position", %{book: book} do
      book = Orderbook.apply_delta(book, :no, 0.41, 5)

      assert Enum.map(book.no, fn {p, _} ->
               p |> Decimal.normalize() |> Decimal.to_string(:normal)
             end) == ["0.43", "0.41", "0.4"]
    end

    test "keeps seq when none is given", %{book: book} do
      book = %{book | seq: 4}
      assert Orderbook.apply_delta(book, :no, "0.40", "1").seq == 4
    end
  end
end
