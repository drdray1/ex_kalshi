defmodule ExKalshi.AuthTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Auth, Fixtures, Signature}

  doctest ExKalshi.Auth

  @stub ExKalshi.AuthTest

  test "signs requests with the three headers over the query-less prefixed path" do
    Req.Test.expect(@stub, fn conn ->
      assert [key] = Plug.Conn.get_req_header(conn, "kalshi-access-key")
      assert [ts] = Plug.Conn.get_req_header(conn, "kalshi-access-timestamp")
      assert [sig] = Plug.Conn.get_req_header(conn, "kalshi-access-signature")

      assert key == Fixtures.key_id()
      assert abs(String.to_integer(ts) - System.system_time(:millisecond)) < 5_000

      assert Signature.verify(
               Fixtures.public_key(),
               ts,
               "GET",
               "/trade-api/v2/portfolio/orders",
               sig
             )

      assert conn.query_string == "limit=5"

      Req.Test.json(conn, %{"orders" => []})
    end)

    client = Fixtures.test_client(@stub)
    assert {:ok, %{"orders" => []}} = ExKalshi.Orders.list_orders(client, limit: 5)
  end

  test "signs the HTTP method that is actually sent" do
    Req.Test.expect(@stub, fn conn ->
      [ts] = Plug.Conn.get_req_header(conn, "kalshi-access-timestamp")
      [sig] = Plug.Conn.get_req_header(conn, "kalshi-access-signature")

      assert Signature.verify(
               Fixtures.public_key(),
               ts,
               "DELETE",
               "/trade-api/v2/portfolio/events/orders/o-1",
               sig
             )

      Req.Test.json(conn, %{})
    end)

    assert {:ok, %{}} = ExKalshi.Orders.cancel_order(Fixtures.test_client(@stub), "o-1")
  end

  test "an unparseable key short-circuits with {:error, {:signature_failed, _}}" do
    client = ExKalshi.Client.new("kid", "garbage", plug: {Req.Test, @stub})

    assert {:error, {:signature_failed, {:invalid_private_key, _}}} =
             ExKalshi.Portfolio.get_balance(client)
  end

  test "public clients send no auth headers" do
    Req.Test.expect(@stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "kalshi-access-key") == []
      Req.Test.json(conn, Fixtures.exchange_status())
    end)

    assert {:ok, _} = ExKalshi.Exchange.status(Fixtures.public_client(@stub))
  end

  test "sign_path/1 handles a nil path" do
    assert Auth.sign_path(%URI{}) == "/trade-api/v2"
  end

  test "api_base_path/0" do
    assert Auth.api_base_path() == "/trade-api/v2"
  end
end
