defmodule ExKalshiTest do
  use ExUnit.Case, async: true

  alias ExKalshi.Fixtures

  @stub ExKalshiTest

  test "new/3 and public/1 build clients" do
    assert %Req.Request{} = ExKalshi.new("k", Fixtures.private_key_pem())
    assert %Req.Request{} = ExKalshi.public(demo: true)
  end

  test "facade delegates round-trip through the stub" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/trade-api/v2/exchange/status" ->
          Req.Test.json(conn, Fixtures.exchange_status())

        "/trade-api/v2/markets" ->
          Req.Test.json(conn, Fixtures.markets_response())

        "/trade-api/v2/portfolio/balance" ->
          Req.Test.json(conn, Fixtures.balance_response())

        "/trade-api/v2/portfolio/events/orders" ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(Fixtures.create_order_response())

        other ->
          flunk("unexpected path #{other}")
      end
    end)

    client = Fixtures.test_client(@stub)
    assert {:ok, %{"exchange_active" => true}} = ExKalshi.exchange_status(client)
    assert {:ok, [_]} = ExKalshi.list_all_markets(client)
    assert {:ok, %{"balance_dollars" => _}} = ExKalshi.get_balance(client)
    assert {:ok, %{"order_id" => _}} = ExKalshi.buy_yes(client, "T", 1, 0.5)
    assert Decimal.equal?(ExKalshi.estimate_fee(100, 0.5), "1.75")
    assert %{ticker: _} = ExKalshi.market_summary(Fixtures.market())
  end

  test "every delegate exists" do
    Code.ensure_loaded!(ExKalshi)

    for {fun, arity} <- [
          verify_credentials: 3,
          exchange_schedule: 1,
          list_markets: 2,
          get_market: 2,
          get_orderbook: 3,
          list_trades: 2,
          get_candlesticks: 4,
          list_events: 2,
          get_event: 3,
          list_series: 2,
          get_series: 2,
          create_order: 2,
          batch_create_orders: 2,
          cancel_order: 3,
          batch_cancel_orders: 2,
          amend_order: 3,
          decrease_order: 3,
          list_orders: 2,
          get_order: 2,
          find_by_client_order_id: 3,
          list_positions: 2,
          list_fills: 2,
          list_settlements: 2,
          sell_yes: 5,
          buy_no: 5,
          sell_no: 5
        ] do
      assert function_exported?(ExKalshi, fun, arity), "#{fun}/#{arity}"
    end
  end
end
