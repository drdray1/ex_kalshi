defmodule ExKalshi.OrdersTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Orders}

  doctest ExKalshi.Orders, only: [format_price: 1, format_count: 1]

  @stub ExKalshi.OrdersTest
  @ticker "KXBTC15M-26AUG272300-00"

  defp read_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  describe "create_order/2" do
    test "posts a fully-formed V2 body with defaults applied" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/trade-api/v2/portfolio/events/orders"
        {body, conn} = read_json(conn)

        assert body == %{
                 "ticker" => @ticker,
                 "side" => "bid",
                 "count" => "10.00",
                 "price" => "0.5600",
                 "time_in_force" => "good_till_canceled",
                 "self_trade_prevention_type" => "taker_at_cross",
                 "client_order_id" => "cid-1",
                 "reduce_only" => true,
                 "post_only" => false
               }

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(Fixtures.create_order_response())
      end)

      assert {:ok, %{"order_id" => "o-1"}} =
               Orders.create_order(Fixtures.test_client(@stub),
                 ticker: @ticker,
                 side: "bid",
                 count: 10,
                 price: 0.56,
                 client_order_id: "cid-1",
                 reduce_only: true,
                 post_only: false,
                 not_a_field: "dropped"
               )
    end

    test "accepts a map with Decimal/string amounts and atoms for enums" do
      Req.Test.expect(@stub, fn conn ->
        {body, conn} = read_json(conn)
        assert body["count"] == "2.50"
        assert body["price"] == "0.1234"
        assert body["side"] == "ask"
        assert body["time_in_force"] == "immediate_or_cancel"
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(Fixtures.create_order_response())
      end)

      assert {:ok, _} =
               Orders.create_order(Fixtures.test_client(@stub), %{
                 ticker: @ticker,
                 side: :ask,
                 count: Decimal.new("2.5"),
                 price: "0.1234",
                 time_in_force: :immediate_or_cancel
               })
    end

    test "validation errors are returned before any request" do
      client = Fixtures.test_client(@stub)

      assert {:error, {:validation_error, errors}} = Orders.create_order(client, %{})
      assert "ticker is required" in errors
      assert Enum.any?(errors, &(&1 =~ "side must be one of"))
      assert "count must be a number" in errors
      assert "price must be a number" in errors

      assert {:error, {:validation_error, errors}} =
               Orders.create_order(client, ticker: @ticker, side: "bid", count: 0, price: 1.0)

      assert "count must be positive" in errors
      assert "price must be between 0 and 1 exclusive" in errors

      assert {:error, {:validation_error, errors}} =
               Orders.create_order(client,
                 ticker: @ticker,
                 side: "bid",
                 count: "abc",
                 price: "0.5x"
               )

      assert "count must be a number" in errors
      assert "price must be a number" in errors

      assert {:error, {:validation_error, errors}} =
               Orders.create_order(client,
                 ticker: @ticker,
                 side: "bid",
                 count: 1,
                 price: 0.5,
                 time_in_force: "gtc",
                 self_trade_prevention_type: "x"
               )

      assert Enum.any?(errors, &(&1 =~ "time_in_force"))
      assert Enum.any?(errors, &(&1 =~ "self_trade_prevention_type"))

      assert {:error, {:validation_error, [msg]}} =
               Orders.create_order(client,
                 ticker: @ticker,
                 side: "bid",
                 count: 1,
                 price: 0.5,
                 time_in_force: "immediate_or_cancel",
                 expiration_time: 99
               )

      assert msg =~ "expiration_time"
    end

    test "API errors surface with the message" do
      Req.Test.expect(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(Fixtures.error_body("insufficient balance"))
      end)

      assert {:error, {:api_error, 400, "insufficient balance"}} =
               Orders.create_order(Fixtures.test_client(@stub),
                 ticker: @ticker,
                 side: "bid",
                 count: 1,
                 price: 0.5
               )
    end

    test "transport failures are not retried" do
      counter = :counters.new(1, [])

      Req.Test.expect(@stub, fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.transport_error(conn, :timeout)
      end)

      client =
        ExKalshi.Client.new(Fixtures.key_id(), Fixtures.private_key_pem(),
          plug: {Req.Test, @stub}
        )

      assert {:error, {:connection_error, %Req.TransportError{reason: :timeout}}} =
               Orders.create_order(client, ticker: @ticker, side: "bid", count: 1, price: 0.5)

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "batch_create_orders/2" do
    test "posts all orders and indexes validation errors" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/portfolio/events/orders/batched"
        {body, conn} = read_json(conn)
        assert [%{"side" => "bid"}, %{"side" => "ask"}] = body["orders"]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "orders" => [Fixtures.create_order_response(), Fixtures.create_order_response()]
        })
      end)

      client = Fixtures.test_client(@stub)

      orders = [
        [ticker: @ticker, side: "bid", count: 1, price: 0.5],
        [ticker: @ticker, side: "ask", count: 1, price: 0.6]
      ]

      assert {:ok, %{"orders" => [_, _]}} = Orders.batch_create_orders(client, orders)

      assert {:error, {:validation_error, ["orders[1]: ticker is required" | _]}} =
               Orders.batch_create_orders(client, [
                 [ticker: @ticker, side: "bid", count: 1, price: 0.5],
                 [side: "bid", count: 1, price: 0.5]
               ])
    end
  end

  describe "cancel_order/3" do
    test "deletes with routing params" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/trade-api/v2/portfolio/events/orders/o-1"
        assert conn.query_string == "market_ticker=T"
        Req.Test.json(conn, Fixtures.cancel_order_response())
      end)

      assert {:ok, %{"reduced_by" => "10.00"}} =
               Orders.cancel_order(Fixtures.test_client(@stub), "o-1", market_ticker: "T")
    end

    test "not found" do
      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      assert {:error, :not_found} = Orders.cancel_order(Fixtures.test_client(@stub), "o-1")
    end
  end

  test "batch_cancel_orders/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/trade-api/v2/portfolio/events/orders/batched"
      {body, conn} = read_json(conn)
      assert body == %{"order_ids" => ["a", "b"]}
      Req.Test.json(conn, %{"orders" => []})
    end)

    assert {:ok, _} = Orders.batch_cancel_orders(Fixtures.test_client(@stub), ["a", "b"])
  end

  describe "amend_order/3" do
    test "posts the amend body" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/portfolio/events/orders/o-1/amend"
        {body, conn} = read_json(conn)

        assert body == %{
                 "ticker" => @ticker,
                 "side" => "bid",
                 "price" => "0.6000",
                 "count" => "12.00",
                 "updated_client_order_id" => "cid-2"
               }

        Req.Test.json(conn, Fixtures.create_order_response())
      end)

      assert {:ok, _} =
               Orders.amend_order(Fixtures.test_client(@stub), "o-1",
                 ticker: @ticker,
                 side: "bid",
                 price: 0.6,
                 count: 12,
                 updated_client_order_id: "cid-2"
               )
    end

    test "validates" do
      assert {:error, {:validation_error, errors}} =
               Orders.amend_order(Fixtures.test_client(@stub), "o-1", %{})

      assert "ticker is required" in errors
    end
  end

  describe "decrease_order/3" do
    test "reduce_by and reduce_to" do
      Req.Test.expect(@stub, 2, fn conn ->
        assert conn.request_path == "/trade-api/v2/portfolio/events/orders/o-1/decrease"
        {body, conn} = read_json(conn)
        assert body in [%{"reduce_by" => "3.00"}, %{"reduce_to" => "1.00", "ticker" => @ticker}]
        Req.Test.json(conn, Fixtures.cancel_order_response())
      end)

      client = Fixtures.test_client(@stub)
      assert {:ok, _} = Orders.decrease_order(client, "o-1", reduce_by: 3)
      assert {:ok, _} = Orders.decrease_order(client, "o-1", reduce_to: 1, ticker: @ticker)
      assert {:error, {:validation_error, _}} = Orders.decrease_order(client, "o-1", %{})
    end
  end

  describe "reads" do
    test "list_orders/2 encodes filters" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/portfolio/orders"
        assert conn.query_string == "ticker=T&status=resting&limit=50&event_ticker=E1%2CE2"
        Req.Test.json(conn, Fixtures.orders_response())
      end)

      assert {:ok, response} =
               Orders.list_orders(Fixtures.test_client(@stub),
                 ticker: "T",
                 status: "resting",
                 limit: 50,
                 event_ticker: ["E1", "E2"]
               )

      assert [%{"order_id" => "o-1"}] = Orders.extract_orders(response)
    end

    test "get_order/2" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path == "/trade-api/v2/portfolio/orders/o-1"
        Req.Test.json(conn, Fixtures.order_response())
      end)

      assert {:ok, response} = Orders.get_order(Fixtures.test_client(@stub), "o-1")
      assert %{"order_id" => "o-1"} = Orders.extract_order(response)
    end

    test "find_by_client_order_id/3" do
      Req.Test.expect(@stub, 2, fn conn ->
        assert conn.query_string == "ticker=T"
        Req.Test.json(conn, Fixtures.orders_response())
      end)

      client = Fixtures.test_client(@stub)

      assert {:ok, %{"order_id" => "o-1"}} =
               Orders.find_by_client_order_id(client, "cid-1", ticker: "T")

      assert {:ok, nil} = Orders.find_by_client_order_id(client, "missing", ticker: "T")

      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
      end)

      assert {:error, :unauthorized} = Orders.find_by_client_order_id(client, "cid-1")
    end
  end

  test "formatting and enums" do
    assert Orders.format_price(1) == "1.0000"
    assert Orders.format_price(0.123456) == "0.1235"
    assert Orders.format_count("7") == "7.00"
    assert Orders.format_count(Decimal.new("0.5")) == "0.50"
    assert Orders.sides() == ["bid", "ask"]
    assert "fill_or_kill" in Orders.time_in_force_values()
    assert Orders.extract_orders(%{}) == []
    assert Orders.extract_order(%{}) == nil
  end
end
