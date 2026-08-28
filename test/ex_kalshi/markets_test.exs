defmodule ExKalshi.MarketsTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Markets, Orderbook}

  @stub ExKalshi.MarketsTest

  describe "list_markets/2" do
    test "encodes filters, csv tickers, and returns markets" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/markets"
        assert conn.query_string == "limit=5&status=open&tickers=A%2CB&series_ticker=KXBTC15M"
        Req.Test.json(conn, Fixtures.markets_response())
      end)

      assert {:ok, %{"markets" => [m]}} =
               Markets.list_markets(Fixtures.public_client(@stub),
                 limit: 5,
                 status: "open",
                 tickers: ["A", "B"],
                 series_ticker: "KXBTC15M",
                 bogus: 1
               )

      assert m["ticker"] == "KXBTC15M-26AUG272300-00"
    end

    test "passes comma-separated tickers through unchanged" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.query_string == "tickers=A%2CB"
        Req.Test.json(conn, Fixtures.markets_response([]))
      end)

      assert {:ok, %{"markets" => []}} =
               Markets.list_markets(Fixtures.public_client(@stub), tickers: "A,B")
    end

    test "rate limited" do
      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{})
      end)

      assert {:error, :rate_limited} = Markets.list_markets(Fixtures.public_client(@stub))
    end
  end

  describe "list_all_markets/2" do
    test "follows cursors until empty" do
      Req.Test.expect(@stub, 3, fn conn ->
        case URI.decode_query(conn.query_string) do
          %{"cursor" => "c2"} ->
            Req.Test.json(
              conn,
              Fixtures.markets_response([Fixtures.market(%{"ticker" => "3"})], "")
            )

          %{"cursor" => "c1"} ->
            Req.Test.json(
              conn,
              Fixtures.markets_response([Fixtures.market(%{"ticker" => "2"})], "c2")
            )

          _ ->
            Req.Test.json(
              conn,
              Fixtures.markets_response([Fixtures.market(%{"ticker" => "1"})], "c1")
            )
        end
      end)

      assert {:ok, markets} =
               Markets.list_all_markets(Fixtures.public_client(@stub),
                 status: "open",
                 cursor: "ignored"
               )

      assert Enum.map(markets, & &1["ticker"]) == ["1", "2", "3"]
    end

    test "stops at the page cap" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, Fixtures.markets_response([Fixtures.market()], "more"))
      end)

      assert {:ok, markets} = Markets.list_all_markets(Fixtures.public_client(@stub))
      assert length(markets) == 50
    end

    test "propagates errors" do
      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      assert {:error, {:api_error, 500, _}} =
               Markets.list_all_markets(Fixtures.public_client(@stub))
    end
  end

  test "get_market/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/markets/KXBTC15M-26AUG272300-00"
      Req.Test.json(conn, Fixtures.market_response())
    end)

    assert {:ok, %{"market" => %{"ticker" => _}}} =
             Markets.get_market(Fixtures.public_client(@stub), "KXBTC15M-26AUG272300-00")
  end

  test "get_market/2 not found" do
    Req.Test.expect(@stub, fn conn -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{}) end)
    assert {:error, :not_found} = Markets.get_market(Fixtures.public_client(@stub), "NOPE")
  end

  test "get_orderbook/3 with depth" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/markets/T/orderbook"
      assert conn.query_string == "depth=5"
      assert [_] = Plug.Conn.get_req_header(conn, "kalshi-access-signature")
      Req.Test.json(conn, Fixtures.orderbook_response())
    end)

    assert {:ok, response} = Markets.get_orderbook(Fixtures.test_client(@stub), "T", depth: 5)
    assert %Orderbook{yes: [{yes_price, _} | _]} = Markets.extract_orderbook(response, "T")
    assert Decimal.equal?(yes_price, "0.55")
  end

  test "list_trades/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/markets/trades"
      assert conn.query_string == "ticker=T&limit=10&min_ts=1&is_block_trade=false"
      Req.Test.json(conn, Fixtures.trades_response())
    end)

    assert {:ok, response} =
             Markets.list_trades(Fixtures.public_client(@stub),
               ticker: "T",
               limit: 10,
               min_ts: 1,
               is_block_trade: false
             )

    assert [%{"trade_id" => "t-1"}] = Markets.extract_trades(response)
  end

  describe "get_candlesticks/4" do
    test "encodes path and params" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/series/KXBTC15M/markets/T/candlesticks"
        assert conn.query_string == "start_ts=1&end_ts=2&period_interval=60"
        Req.Test.json(conn, Fixtures.candlesticks_response())
      end)

      assert {:ok, response} =
               Markets.get_candlesticks(Fixtures.public_client(@stub), "KXBTC15M", "T",
                 start_ts: 1,
                 end_ts: 2,
                 period_interval: 60
               )

      assert [%{"end_period_ts" => _}] = Markets.extract_candlesticks(response)
    end

    test "validates required options and period" do
      client = Fixtures.public_client(@stub)

      assert {:error, {:validation_error, [msg]}} =
               Markets.get_candlesticks(client, "S", "T", start_ts: 1)

      assert msg =~ "missing required options"

      assert {:error, {:validation_error, [msg]}} =
               Markets.get_candlesticks(client, "S", "T",
                 start_ts: 1,
                 end_ts: 2,
                 period_interval: 5
               )

      assert msg =~ "period_interval"
    end
  end

  test "extractors tolerate malformed input" do
    assert Markets.extract_markets(%{}) == []
    assert Markets.extract_markets(%{"markets" => "x"}) == []
    assert Markets.extract_market(%{}) == nil
    assert Markets.extract_cursor(%{"cursor" => ""}) == nil
    assert Markets.extract_cursor(%{"cursor" => nil}) == nil
    assert Markets.extract_cursor(%{"cursor" => "abc"}) == "abc"
    assert Markets.extract_trades(%{}) == []
    assert Markets.extract_candlesticks(nil) == []
    assert %Orderbook{yes: [], no: []} = Markets.extract_orderbook(%{})
  end
end
