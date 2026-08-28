defmodule ExKalshi.PortfolioTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Portfolio}

  @stub ExKalshi.PortfolioTest

  test "get_balance/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/balance"
      assert conn.query_string == "subaccount=2"
      Req.Test.json(conn, Fixtures.balance_response())
    end)

    assert {:ok, response} = Portfolio.get_balance(Fixtures.test_client(@stub), subaccount: 2)
    assert Decimal.equal?(Portfolio.available_balance(response), "1234.56")
  end

  test "available_balance/1 fallbacks" do
    assert Decimal.equal?(Portfolio.available_balance(%{"balance" => 250}), "2.5")
    assert Decimal.equal?(Portfolio.available_balance(%{}), 0)
  end

  test "list_positions/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/positions"
      assert conn.query_string == "ticker=T&count_filter=position&limit=10"
      Req.Test.json(conn, Fixtures.positions_response())
    end)

    assert {:ok, response} =
             Portfolio.list_positions(Fixtures.test_client(@stub),
               ticker: "T",
               count_filter: "position",
               limit: 10
             )

    assert [_, _] = Portfolio.extract_market_positions(response)
    assert [_] = Portfolio.extract_event_positions(response)

    assert %{"position_fp" => "-4.00"} =
             Portfolio.find_position(response, "KXBTC15M-26AUG272300-01")

    assert Portfolio.find_position(response, "nope") == nil
  end

  test "list_fills/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/fills"
      assert conn.query_string == "order_id=o-1&min_ts=5"
      Req.Test.json(conn, Fixtures.fills_response())
    end)

    assert {:ok, response} =
             Portfolio.list_fills(Fixtures.test_client(@stub), order_id: "o-1", min_ts: 5)

    assert [%{"fill_id" => "f-1"}] = Portfolio.extract_fills(response)
  end

  test "list_settlements/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/settlements"
      assert conn.query_string == "limit=5"
      Req.Test.json(conn, Fixtures.settlements_response())
    end)

    assert {:ok, response} = Portfolio.list_settlements(Fixtures.test_client(@stub), limit: 5)
    assert [%{"market_result" => "yes"}] = Portfolio.extract_settlements(response)
  end

  test "resting_order_value/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/portfolio/summary/total_resting_order_value"
      Req.Test.json(conn, %{"total_resting_order_value_dollars" => "5.0000"})
    end)

    assert {:ok, %{"total_resting_order_value_dollars" => _}} =
             Portfolio.resting_order_value(Fixtures.test_client(@stub))
  end

  test "unauthorized" do
    Req.Test.expect(@stub, fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end)
    assert {:error, :unauthorized} = Portfolio.get_balance(Fixtures.test_client(@stub))
  end

  test "empty extractors" do
    assert Portfolio.extract_market_positions(%{}) == []
    assert Portfolio.extract_event_positions(%{}) == []
    assert Portfolio.extract_fills(%{}) == []
    assert Portfolio.extract_settlements(%{}) == []
  end
end
