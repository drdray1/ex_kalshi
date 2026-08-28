defmodule ExKalshi.ExchangeTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Exchange, Fixtures}

  @stub ExKalshi.ExchangeTest

  test "status/1" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/exchange/status"
      Req.Test.json(conn, Fixtures.exchange_status())
    end)

    assert {:ok, %{"exchange_active" => true}} = Exchange.status(Fixtures.public_client(@stub))
  end

  test "schedule/1" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/exchange/schedule"
      Req.Test.json(conn, %{"schedule" => %{"standard_hours" => [], "maintenance_windows" => []}})
    end)

    assert {:ok, %{"schedule" => _}} = Exchange.schedule(Fixtures.public_client(@stub))
  end

  test "status/1 surfaces server errors" do
    Req.Test.expect(@stub, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(Fixtures.error_body("down"))
    end)

    assert {:error, {:api_error, 503, "down"}} = Exchange.status(Fixtures.public_client(@stub))
  end

  test "trading_active?/1" do
    assert Exchange.trading_active?(Fixtures.exchange_status())
    refute Exchange.trading_active?(%{"exchange_active" => true, "trading_active" => false})
    refute Exchange.trading_active?(%{})
  end
end
