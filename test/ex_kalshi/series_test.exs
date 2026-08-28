defmodule ExKalshi.SeriesTest do
  use ExUnit.Case, async: true

  alias ExKalshi.{Fixtures, Series}

  @stub ExKalshi.SeriesTest

  test "list_series/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/series"
      assert conn.query_string == "category=Crypto&tags=a%2Cb&include_volume=true"
      Req.Test.json(conn, Fixtures.series_list_response())
    end)

    assert {:ok, response} =
             Series.list_series(Fixtures.public_client(@stub),
               category: "Crypto",
               tags: ["a", "b"],
               include_volume: true
             )

    assert [%{"ticker" => "KXBTC15M"}] = Series.extract_series_list(response)
  end

  test "get_series/2" do
    Req.Test.expect(@stub, fn conn ->
      assert conn.request_path == "/trade-api/v2/series/KXBTC15M"
      Req.Test.json(conn, Fixtures.series_response())
    end)

    assert {:ok, response} = Series.get_series(Fixtures.public_client(@stub), "KXBTC15M")
    assert %{"fee_multiplier" => 0.07} = Series.extract_series(response)
  end

  test "errors and empty extractors" do
    Req.Test.expect(@stub, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(Fixtures.error_body())
    end)

    assert {:error, {:api_error, 500, "bad things"}} =
             Series.get_series(Fixtures.public_client(@stub), "X")

    assert Series.extract_series_list(%{}) == []
    assert Series.extract_series(%{}) == nil
  end
end
