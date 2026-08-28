defmodule ExKalshi.EventsTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Events, Fixtures}

  @stub ExKalshi.EventsTest

  test "list_events/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/events"
      assert conn.query_string == "limit=10&status=open&with_nested_markets=true&tickers=E1%2CE2"
      Req.Test.json(conn, Fixtures.events_response())
    end)

    assert {:ok, response} =
             Events.list_events(Fixtures.public_client(@stub),
               limit: 10,
               status: "open",
               with_nested_markets: true,
               tickers: ["E1", "E2"]
             )

    assert [%{"event_ticker" => "KXBTC15M-26AUG272300"}] = Events.extract_events(response)
  end

  test "get_event/3" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/events/KXBTC15M-26AUG272300"
      assert conn.query_string == "with_nested_markets=true"
      Req.Test.json(conn, Fixtures.event_response())
    end)

    assert {:ok, response} =
             Events.get_event(Fixtures.public_client(@stub), "KXBTC15M-26AUG272300",
               with_nested_markets: true
             )

    assert %{"event_ticker" => _} = Events.extract_event(response)
    assert [%{"ticker" => _}] = Events.extract_markets(response)
  end

  test "get_event/3 error" do
    Req.Test.expect(@stub, fn conn -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{}) end)
    assert {:error, :not_found} = Events.get_event(Fixtures.public_client(@stub), "X")
  end

  test "extractors" do
    assert Events.extract_events(%{}) == []
    assert Events.extract_event(%{}) == nil
    assert Events.extract_markets(Fixtures.event()) == [Fixtures.market()]
    assert Events.extract_markets(%{}) == []
  end
end
