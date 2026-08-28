defmodule ExKalshi.WebSocketTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Orderbook, WebSocket}

  doctest ExKalshi.WebSocket

  describe "commands" do
    test "subscribe with and without tickers" do
      assert WebSocket.subscribe(1, [:ticker, "trade"], ["A"]) ==
               %{
                 "id" => 1,
                 "cmd" => "subscribe",
                 "params" => %{"channels" => ["ticker", "trade"], "market_tickers" => ["A"]}
               }

      assert WebSocket.subscribe(2, [:fill]) == %{
               "id" => 2,
               "cmd" => "subscribe",
               "params" => %{"channels" => ["fill"]}
             }
    end

    test "unsubscribe, update_subscription, list_subscriptions" do
      assert WebSocket.unsubscribe(3, [1, 2]) == %{
               "id" => 3,
               "cmd" => "unsubscribe",
               "params" => %{"sids" => [1, 2]}
             }

      assert WebSocket.update_subscription(4, [1], ["B"], "add_markets") ==
               %{
                 "id" => 4,
                 "cmd" => "update_subscription",
                 "params" => %{
                   "sids" => [1],
                   "market_tickers" => ["B"],
                   "action" => "add_markets"
                 }
               }

      assert WebSocket.list_subscriptions(5) == %{"id" => 5, "cmd" => "list_subscriptions"}
    end

    test "validate_channels!/1" do
      assert WebSocket.validate_channels!([:ticker, :ticker, "fill"]) == ["ticker", "fill"]
      assert_raise ArgumentError, ~r/bogus/, fn -> WebSocket.validate_channels!([:bogus]) end
      assert "orderbook_delta" in WebSocket.channels()
    end

    test "handshake_headers/2 signs GET /trade-api/ws/v2" do
      assert {:ok,
              [
                {"KALSHI-ACCESS-KEY", "k"},
                {"KALSHI-ACCESS-TIMESTAMP", ts},
                {"KALSHI-ACCESS-SIGNATURE", sig}
              ]} =
               WebSocket.handshake_headers("k", Fixtures.private_key_pem())

      assert ExKalshi.Signature.verify(Fixtures.public_key(), ts, "GET", "/trade-api/ws/v2", sig)
      assert {:error, {:invalid_private_key, _}} = WebSocket.handshake_headers("k", "bad")
    end

    test "websocket_url/1" do
      assert WebSocket.websocket_url() =~ "external-api-ws.kalshi.com"
      assert WebSocket.websocket_url(true) =~ "demo"
    end
  end

  describe "parse_message/1" do
    defp parse(map), do: map |> Jason.encode!() |> WebSocket.parse_message()

    test "subscribed / ok / error / subscriptions" do
      assert {:ok, :subscribed, %WebSocket.SubscribedEvent{id: 1, sid: 7, channel: "ticker"}} =
               parse(Fixtures.ws_subscribed())

      assert {:ok, :ok,
              %WebSocket.OkEvent{id: 2, sid: 7, seq: 1, msg: %{"market_tickers" => ["A"]}}} =
               parse(Fixtures.ws_ok())

      assert {:ok, :error, %WebSocket.ErrorEvent{id: 1, code: 6, message: "Already subscribed"}} =
               parse(Fixtures.ws_error())

      assert {:ok, :subscriptions, %WebSocket.SubscriptionsEvent{subscriptions: [%{"sid" => 1}]}} =
               parse(%{
                 "id" => 3,
                 "type" => "subscriptions",
                 "msg" => %{"subscriptions" => [%{"sid" => 1}]}
               })

      assert {:ok, :error, %WebSocket.ErrorEvent{message: nil}} = parse(%{"type" => "error"})
    end

    test "orderbook snapshot and delta" do
      assert {:ok, :orderbook_snapshot,
              %WebSocket.OrderbookSnapshotEvent{
                sid: 7,
                seq: 1,
                market_ticker: "KXBTC15M-26AUG272300-00",
                book: %Orderbook{seq: 1} = book
              }} = parse(Fixtures.ws_orderbook_snapshot())

      assert length(book.yes) == 2

      assert {:ok, :orderbook_delta,
              %WebSocket.OrderbookDeltaEvent{
                sid: 7,
                seq: 2,
                side: :yes,
                price: price,
                delta: delta,
                ts_ms: 1_669_149_841_000
              }} = parse(Fixtures.ws_orderbook_delta())

      assert Decimal.equal?(price, "0.22") and Decimal.equal?(delta, -33)

      book = Orderbook.apply_delta(book, :yes, price, delta, 2)
      assert [{_, count} | _] = book.yes
      assert Decimal.equal?(count, 300)
    end

    test "ticker" do
      assert {:ok, :ticker, %WebSocket.TickerEvent{} = e} = parse(Fixtures.ws_ticker())
      assert e.market_ticker == "KXBTC15M-26AUG272300-00"
      assert Decimal.equal?(e.price, "0.48")
      assert Decimal.equal?(e.yes_bid, "0.45")
      assert Decimal.equal?(e.yes_ask, "0.53")
      assert Decimal.equal?(e.volume, 33_896)
      assert Decimal.equal?(e.yes_bid_size, 300)
      assert e.ts_ms == 1_669_149_841_000
      assert e.raw["ts"] == 1_669_149_841
    end

    test "trade" do
      assert {:ok, :trade, %WebSocket.TradeEvent{trade_id: "t-1", taker_side: "yes"} = e} =
               parse(Fixtures.ws_trade())

      assert Decimal.equal?(e.yes_price, "0.56")
      assert Decimal.equal?(e.count, 5)
    end

    test "fill" do
      assert {:ok, :fill,
              %WebSocket.FillEvent{
                order_id: "ee587a1c",
                client_order_id: "cid-1",
                action: "buy",
                side: "yes",
                is_taker: true,
                subaccount: 0
              } = e} = parse(Fixtures.ws_fill())

      assert Decimal.equal?(e.yes_price, "0.75")
      assert Decimal.equal?(e.count, 278)
      assert Decimal.equal?(e.fee_cost, 0)
      assert Decimal.equal?(e.post_position, 500)
    end

    test "user orders (nested and flat, both type spellings)" do
      assert {:ok, :user_orders,
              %WebSocket.UserOrderEvent{
                order_id: "o-1",
                client_order_id: "cid-1",
                status: "resting",
                market_ticker: "KXBTC15M-26AUG272300-00",
                ts_ms: 5
              } = e} = parse(Fixtures.ws_user_order())

      assert Decimal.equal?(e.count, 10)
      assert Decimal.equal?(e.remaining_count, 10)
      assert Decimal.equal?(e.fill_count, 0)

      flat = %{
        "type" => "user_orders",
        "sid" => 1,
        "seq" => 1,
        "msg" => %{
          "order_id" => "o-2",
          "market_ticker" => "T",
          "count_fp" => "3.00",
          "ts_ms" => 9
        }
      }

      assert {:ok, :user_orders,
              %WebSocket.UserOrderEvent{order_id: "o-2", market_ticker: "T", ts_ms: 9}} =
               parse(flat)
    end

    test "market lifecycle" do
      assert {:ok, :market_lifecycle,
              %WebSocket.MarketLifecycleEvent{
                event_type: "close",
                market_ticker: "KXBTC15M-26AUG272300-00"
              }} = parse(Fixtures.ws_lifecycle())
    end

    test "unknown data types are wrapped, bad input rejected" do
      assert {:ok, :unknown,
              %WebSocket.GenericEvent{type: "pyth_value", sid: 12, msg: %{"value" => "1"}}} =
               parse(Fixtures.ws_unknown())

      assert {:error, :invalid_json} = WebSocket.parse_message("{nope")
      assert {:error, :missing_type} = WebSocket.parse_message("{}")
      assert {:error, :missing_type} = WebSocket.parse_map(%{"x" => 1})
    end

    test "delta with unexpected side yields nil side" do
      assert {:ok, :orderbook_delta, %{side: nil}} =
               parse(put_in(Fixtures.ws_orderbook_delta(), ["msg", "side"], "maybe"))
    end
  end
end
