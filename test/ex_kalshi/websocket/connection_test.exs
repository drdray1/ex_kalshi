defmodule ExKalshi.WebSocket.ConnectionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias ExKalshi.Fixtures
  alias ExKalshi.WebSocket
  alias ExKalshi.WebSocket.Connection

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(ExKalshi.WebSocket.Client, :start_link, fn _url, _parent, opts ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:ws_started, pid, opts})
      {:ok, pid}
    end)

    stub(ExKalshi.WebSocket.Client, :send_message, fn _pid, msg ->
      send(test_pid, {:sent, msg})
      :ok
    end)

    stub(ExKalshi.WebSocket.Client, :close, fn _pid -> :ok end)
    :ok
  end

  defp start(opts \\ []) do
    default = [key_id: Fixtures.key_id(), private_key_pem: Fixtures.private_key_pem()]
    {:ok, pid} = Connection.start_link(Keyword.merge(default, opts))
    on_exit(fn -> if Process.alive?(pid), do: Connection.stop(pid) end)
    pid
  end

  defp connect(conn) do
    assert_receive {:ws_started, ws, _opts}
    send(conn, {:stream_connected, ws})
    ws
  end

  defp push(conn, ws, map), do: send(conn, {:stream_message, ws, Jason.encode!(map)})

  describe "start_link/1" do
    test "starts disconnected and reports info" do
      conn = start()
      assert Connection.get_status(conn) == :disconnected

      assert %{
               status: :disconnected,
               subscriptions: [],
               authenticated: true,
               demo: false,
               subscriber_count: 0
             } = Connection.get_info(conn)
    end

    test "public mode" do
      conn = start(key_id: nil, private_key_pem: nil)
      assert %{authenticated: false} = Connection.get_info(conn)
    end

    test "rejects half-given credentials" do
      assert_raise ArgumentError, fn -> Connection.start_link(key_id: "k") end
    end

    test "registers a name" do
      start(name: :kalshi_test_conn)
      assert Process.whereis(:kalshi_test_conn)
    end
  end

  describe "subscribe/3" do
    test "connects lazily with fresh signed headers and sends the subscribe after connect" do
      conn = start(demo: true)
      assert :ok = Connection.subscribe(conn, [:ticker], ["A"])
      assert Connection.get_status(conn) == :connecting

      assert_receive {:ws_started, ws, opts}

      assert [
               {"KALSHI-ACCESS-KEY", _},
               {"KALSHI-ACCESS-TIMESTAMP", ts},
               {"KALSHI-ACCESS-SIGNATURE", sig}
             ] = opts[:extra_headers]

      assert ExKalshi.Signature.verify(Fixtures.public_key(), ts, "GET", "/trade-api/ws/v2", sig)

      send(conn, {:stream_connected, ws})

      assert_receive {:sent,
                      %{
                        "id" => 1,
                        "cmd" => "subscribe",
                        "params" => %{"channels" => ["ticker"], "market_tickers" => ["A"]}
                      }}

      assert Connection.get_status(conn) == :connected
    end

    test "public connections send no headers" do
      conn = start(key_id: nil, private_key_pem: nil)
      Connection.subscribe(conn, [:ticker])
      assert_receive {:ws_started, _ws, opts}
      assert opts[:extra_headers] == []
    end

    test "raises on unknown channels and dedupes identical subscriptions" do
      conn = start()
      assert_raise ArgumentError, fn -> Connection.subscribe(conn, [:nope]) end
      Connection.subscribe(conn, [:fill])
      Connection.subscribe(conn, [:fill])
      assert %{subscriptions: [{["fill"], []}]} = Connection.get_info(conn)
    end

    test "sends immediately when already connected and maps sids" do
      conn = start()
      Connection.subscribe(conn, [:ticker], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))

      Connection.subscribe(conn, [:fill])
      assert_receive {:sent, %{"id" => 2, "params" => %{"channels" => ["fill"]}}}
      push(conn, ws, Fixtures.ws_subscribed(2, 8, "fill"))

      assert %{
               sids: %{
                 7 => %{channel: "ticker", tickers: ["A"]},
                 8 => %{channel: "fill", tickers: []}
               }
             } = Connection.get_info(conn)
    end

    test "multi-channel subscribe keeps the pending entry until each channel reports" do
      conn = start()
      Connection.subscribe(conn, [:ticker, :trade], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))
      push(conn, ws, Fixtures.ws_subscribed(1, 8, "trade"))

      assert %{sids: %{7 => %{tickers: ["A"]}, 8 => %{tickers: ["A"]}}} =
               Connection.get_info(conn)
    end
  end

  describe "events" do
    test "broadcasts parsed data events to subscribers and tracks seq" do
      conn = start()
      Connection.add_subscriber(conn, self())
      Connection.subscribe(conn, [:ticker], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))
      push(conn, ws, Fixtures.ws_ticker(7, 1))
      assert_receive {:kalshi_event, :ticker, %WebSocket.TickerEvent{sid: 7, seq: 1}}
      push(conn, ws, Fixtures.ws_ticker(7, 2))
      assert_receive {:kalshi_event, :ticker, %WebSocket.TickerEvent{seq: 2}}
      assert %{sids: %{7 => %{seq: 2}}} = Connection.get_info(conn)
      refute_receive {:sent, %{"cmd" => "unsubscribe"}}
    end

    test "a sequence gap triggers unsubscribe + resubscribe of that sid" do
      conn = start()
      Connection.add_subscriber(conn, self())
      Connection.subscribe(conn, [:orderbook_delta], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "orderbook_delta"))
      push(conn, ws, Fixtures.ws_orderbook_snapshot(7, 1))
      assert_receive {:kalshi_event, :orderbook_snapshot, _}
      push(conn, ws, Fixtures.ws_orderbook_delta(7, 5))
      assert_receive {:kalshi_event, :orderbook_delta, _}
      assert_receive {:sent, %{"cmd" => "unsubscribe", "params" => %{"sids" => [7]}}}

      assert_receive {:sent,
                      %{
                        "cmd" => "subscribe",
                        "params" => %{
                          "channels" => ["orderbook_delta"],
                          "market_tickers" => ["A"]
                        }
                      }}

      assert %{sids: sids} = Connection.get_info(conn)
      refute Map.has_key?(sids, 7)
    end

    test "errors are broadcast and clear the pending id; ok/subscriptions/unparseable are ignored" do
      conn = start()
      Connection.add_subscriber(conn, self())
      Connection.subscribe(conn, [:fill])
      ws = connect(conn)
      push(conn, ws, Fixtures.ws_error(1))
      assert_receive {:kalshi_event, :error, %WebSocket.ErrorEvent{code: 6}}
      push(conn, ws, Fixtures.ws_ok(9))
      push(conn, ws, %{"id" => 3, "type" => "subscriptions", "msg" => %{"subscriptions" => []}})
      send(conn, {:stream_message, ws, "{bad"})
      send(conn, {:stream_binary, ws, <<0>>})
      send(conn, :unexpected)
      assert Connection.get_status(conn) == :connected
    end

    test "unknown data types are forwarded as :unknown" do
      conn = start()
      Connection.add_subscriber(conn, self())
      Connection.subscribe(conn, [:pyth_value])
      ws = connect(conn)
      push(conn, ws, Fixtures.ws_unknown())
      assert_receive {:kalshi_event, :unknown, %WebSocket.GenericEvent{type: "pyth_value"}}
    end
  end

  describe "subscribers" do
    test "add/remove and monitor cleanup" do
      conn = start()
      other = spawn(fn -> receive do: (:stop -> :ok) end)
      Connection.add_subscriber(conn, self())
      Connection.add_subscriber(conn, other)
      assert %{subscriber_count: 2} = Connection.get_info(conn)
      Connection.remove_subscriber(conn, self())
      assert %{subscriber_count: 1} = Connection.get_info(conn)
      send(other, :stop)
      Process.sleep(20)
      assert %{subscriber_count: 0} = Connection.get_info(conn)
    end
  end

  describe "unsubscribe/3" do
    test "removes desired and sends unsubscribe for matching sids" do
      conn = start()
      Connection.subscribe(conn, [:ticker], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))
      assert :ok = Connection.unsubscribe(conn, [:ticker], ["A"])
      assert_receive {:sent, %{"cmd" => "unsubscribe", "params" => %{"sids" => [7]}}}
      assert %{subscriptions: [], sids: sids} = Connection.get_info(conn)
      assert sids == %{}
    end

    test "no-op when nothing matches" do
      conn = start()
      assert :ok = Connection.unsubscribe(conn, [:ticker], ["Z"])
      refute_receive {:sent, _}
    end
  end

  describe "reconnection" do
    test "disconnect schedules a reconnect that replays subscriptions with new headers" do
      conn = start()
      Connection.subscribe(conn, [:ticker], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))

      send(conn, {:stream_disconnected, ws, :closed})
      assert Connection.get_status(conn) == :reconnecting
      send(conn, :reconnect)
      assert_receive {:ws_started, ws2, opts}
      assert [_, {"KALSHI-ACCESS-TIMESTAMP", _}, _] = opts[:extra_headers]
      send(conn, {:stream_connected, ws2})

      assert_receive {:sent,
                      %{
                        "cmd" => "subscribe",
                        "params" => %{"channels" => ["ticker"], "market_tickers" => ["A"]}
                      }}

      assert %{sids: sids} = Connection.get_info(conn)
      assert sids == %{}
    end

    test "reconnect/1 drops the socket and reschedules" do
      conn = start()
      Connection.subscribe(conn, [:ticker])
      connect(conn)
      Connection.reconnect(conn)
      assert Connection.get_status(conn) == :reconnecting
    end

    test "connect failure schedules a retry" do
      stub(ExKalshi.WebSocket.Client, :start_link, fn _url, _parent, _opts ->
        {:error, :refused}
      end)

      conn = start()
      Connection.subscribe(conn, [:ticker])
      assert Connection.get_status(conn) == :reconnecting
    end

    test "bad key never opens a socket" do
      conn = start(private_key_pem: "garbage")
      Connection.subscribe(conn, [:ticker])
      refute_receive {:ws_started, _, _}
      assert Connection.get_status(conn) == :reconnecting
    end

    test "gives up after the max attempts" do
      stub(ExKalshi.WebSocket.Client, :start_link, fn _url, _parent, _opts ->
        {:error, :refused}
      end)

      conn = start()
      Connection.subscribe(conn, [:ticker])
      for _ <- 1..12, do: send(conn, :reconnect)
      Process.sleep(20)
      assert Connection.get_status(conn) == :disconnected
    end

    test "backoff is exponential and capped" do
      assert Connection.backoff_delay(0) == 1_000
      assert Connection.backoff_delay(3) == 8_000
      assert Connection.backoff_delay(10) == 30_000
    end
  end

  describe "terminate" do
    test "unsubscribes active sids and closes" do
      conn = start()
      Connection.subscribe(conn, [:ticker], ["A"])
      ws = connect(conn)
      assert_receive {:sent, %{"id" => 1}}
      push(conn, ws, Fixtures.ws_subscribed(1, 7, "ticker"))
      Connection.stop(conn)
      assert_receive {:sent, %{"cmd" => "unsubscribe", "params" => %{"sids" => [7]}}}
    end

    test "stops cleanly when never connected" do
      conn = start()
      assert :ok = Connection.stop(conn)
    end
  end
end
