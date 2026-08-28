defmodule ExKalshi.PredictionsTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Orderbook, Predictions}

  doctest ExKalshi.Predictions,
    only: [
      no_to_yes_price: 1,
      estimate_fee: 3,
      position_side: 1,
      to_coinbase_product_id: 1,
      from_coinbase_product_id: 1
    ]

  @stub ExKalshi.PredictionsTest
  @ticker "KXBTC15M-26AUG272300-00"

  defp expect_order(expected) do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/events/orders"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      for {k, v} <- expected do
        assert decoded[k] == v, "expected #{k}=#{inspect(v)}, got #{inspect(decoded[k])}"
      end

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(Fixtures.create_order_response())
    end)
  end

  describe "trading helpers" do
    test "buy_yes is a bid at price with options passed through" do
      expect_order(%{
        "side" => "bid",
        "price" => "0.5600",
        "count" => "10.00",
        "client_order_id" => "c",
        "reduce_only" => true,
        "time_in_force" => "immediate_or_cancel"
      })

      assert {:ok, _} =
               Predictions.buy_yes(Fixtures.test_client(@stub), @ticker, 10, 0.56,
                 client_order_id: "c",
                 reduce_only: true,
                 time_in_force: "immediate_or_cancel"
               )
    end

    test "sell_yes is an ask at price" do
      expect_order(%{"side" => "ask", "price" => "0.5600"})
      assert {:ok, _} = Predictions.sell_yes(Fixtures.test_client(@stub), @ticker, 1, "0.56")
    end

    test "buy_no is an ask at 1 - price" do
      expect_order(%{"side" => "ask", "price" => "0.7000"})
      assert {:ok, _} = Predictions.buy_no(Fixtures.test_client(@stub), @ticker, 1, 0.30)
    end

    test "sell_no is a bid at 1 - price" do
      expect_order(%{"side" => "bid", "price" => "0.7000"})

      assert {:ok, _} =
               Predictions.sell_no(Fixtures.test_client(@stub), @ticker, 1, Decimal.new("0.3"))
    end

    test "validation errors propagate" do
      assert {:error, {:validation_error, _}} =
               Predictions.buy_yes(Fixtures.test_client(@stub), @ticker, 0, 0.5)
    end

    test "order_params/6 builds every combination" do
      assert %{side: "bid", price: p} = Predictions.order_params("T", :buy, :yes, 1, 0.3)
      assert Decimal.equal?(p, "0.3")
      assert %{side: "ask"} = Predictions.order_params("T", :sell, :yes, 1, 0.3)

      assert %{side: "ask", price: p} =
               Predictions.order_params("T", :buy, :no, 1, 0.3, client_order_id: "x")

      assert Decimal.equal?(p, "0.7")

      assert %{side: "bid", price: p, client_order_id: "x"} =
               Predictions.order_params("T", :sell, :no, 1, 0.3, client_order_id: "x")

      assert Decimal.equal?(p, "0.7")
    end
  end

  describe "price math" do
    test "conversions are symmetric" do
      assert Decimal.equal?(Predictions.yes_to_no_price("0.25"), "0.75")

      assert Decimal.equal?(
               Predictions.no_to_yes_price(Predictions.yes_to_no_price(0.25)),
               "0.25"
             )

      assert Decimal.equal?(Predictions.implied_probability("0.4200"), "0.42")
    end

    test "fee table (multiplier 0.07, ceil to cent)" do
      for {count, price, expected} <- [
            {100, 0.5, "1.75"},
            {1, 0.5, "0.02"},
            {10, 0.1, "0.07"},
            {10, 0.99, "0.01"},
            {3, 0.33, "0.05"},
            {1, 0.01, "0.01"}
          ] do
        assert Decimal.equal?(Predictions.estimate_fee(count, price), expected),
               "#{count}@#{price} -> #{expected}"
      end
    end

    test "fee with a custom multiplier and Decimal inputs" do
      assert Decimal.equal?(
               Predictions.estimate_fee(Decimal.new(100), Decimal.new("0.5"), "0.035"),
               "0.88"
             )

      assert Decimal.equal?(Predictions.estimate_fee(100, 0.5, 0), 0)
    end

    test "cost, payout, profit" do
      assert Decimal.equal?(Predictions.cost(10, 0.56), "5.6")
      assert Decimal.equal?(Predictions.max_payout(10), 10)
      assert Decimal.equal?(Predictions.max_profit(10, 0.56), "4.4")
    end
  end

  describe "orderbook helpers" do
    test "best prices, mid and spread" do
      book = Orderbook.from_rest(Fixtures.orderbook_response(), "T")
      assert Decimal.equal?(Predictions.best_yes_bid(book), "0.55")
      assert Decimal.equal?(Predictions.best_yes_ask(book), "0.57")
      assert Decimal.equal?(Predictions.best_no_bid(book), "0.43")
      assert Decimal.equal?(Predictions.best_no_ask(book), "0.45")
      assert Decimal.equal?(Predictions.mid_price(book), "0.56")
      assert Decimal.equal?(Predictions.spread(book), "0.02")
    end

    test "empty book" do
      assert Predictions.best_yes_bid(%Orderbook{}) == nil
      assert Predictions.best_no_bid(%Orderbook{}) == nil
      assert Predictions.mid_price(%Orderbook{}) == nil
      assert Predictions.spread(%Orderbook{yes: [{Decimal.new("0.5"), Decimal.new(1)}]}) == nil
    end
  end

  describe "positions and markets" do
    test "position_side/1 and position_count/1" do
      assert Predictions.position_side(%{"position_fp" => "10.00"}) == :yes
      assert Predictions.position_side(%{"position_fp" => "0.00"}) == :flat
      assert Predictions.position_side(%{"position" => -3}) == :no
      assert Predictions.position_side(%{}) == :flat
      assert Predictions.position_side(2.0) == :yes
      assert Decimal.equal?(Predictions.position_count(%{"position_fp" => "-4.00"}), 4)
      assert Decimal.equal?(Predictions.position_count(%{"position" => -3}), 3)
      assert Decimal.equal?(Predictions.position_count(%{}), 0)
    end

    test "market_summary/1" do
      summary = Predictions.market_summary(Fixtures.market())
      assert summary.ticker == @ticker
      assert summary.status == "open"
      assert Decimal.equal?(summary.yes_bid, "0.55")
      assert Decimal.equal?(summary.no_ask, "0.45")
      assert Decimal.equal?(summary.volume, 1234)
      assert summary.close_time == "2026-08-27T23:00:00Z"

      sparse =
        Predictions.market_summary(%{
          "ticker" => "X",
          "yes_sub_title" => "sub",
          "last_price_dollars" => ""
        })

      assert sparse.title == "sub"
      assert sparse.yes_bid == nil
      assert sparse.last_price == nil
    end

    test "tradable?/1" do
      assert Predictions.tradable?(Fixtures.market())
      refute Predictions.tradable?(Fixtures.market(%{"status" => "closed"}))
    end
  end

  test "coinbase bridge round-trips and is idempotent" do
    product = Predictions.to_coinbase_product_id(@ticker)
    assert product == @ticker <> "-KALSHI"
    assert Predictions.to_coinbase_product_id(product) == product
    assert Predictions.from_coinbase_product_id(product) == @ticker
    assert Predictions.from_coinbase_product_id(@ticker) == @ticker
  end
end
