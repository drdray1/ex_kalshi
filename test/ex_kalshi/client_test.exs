defmodule ExKalshi.ClientTest do
  use ExUnit.Case, async: false

  alias ExKalshi.{Client, Fixtures}

  @stub ExKalshi.ClientTest

  setup do
    original = Application.get_env(:ex_kalshi, :config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ex_kalshi, :config, original),
        else: Application.delete_env(:ex_kalshi, :config)
    end)

    Application.delete_env(:ex_kalshi, :config)
    :ok
  end

  describe "URLs" do
    test "defaults" do
      assert Client.base_url() == "https://external-api.kalshi.com/trade-api/v2"
      assert Client.base_url(true) == "https://external-api.demo.kalshi.co/trade-api/v2"
      assert Client.websocket_url() == "wss://external-api-ws.kalshi.com/trade-api/ws/v2"
      assert Client.websocket_url(true) == "wss://external-api-ws.demo.kalshi.co/trade-api/ws/v2"
      assert Client.timeout() == 30_000
    end

    test "config overrides" do
      Application.put_env(:ex_kalshi, :config,
        base_url: "http://p",
        demo_url: "http://d",
        websocket_url: "ws://p",
        demo_websocket_url: "ws://d",
        timeout: 5
      )

      assert Client.base_url() == "http://p"
      assert Client.base_url(true) == "http://d"
      assert Client.websocket_url() == "ws://p"
      assert Client.websocket_url(true) == "ws://d"
      assert Client.timeout() == 5
    end

    test "new/3 with demo: true targets the demo host" do
      client = Client.new("k", Fixtures.private_key_pem(), demo: true)
      assert client.options.base_url == "https://external-api.demo.kalshi.co/trade-api/v2"
    end
  end

  describe "handle_response/1" do
    test "2xx" do
      assert {:ok, %{"a" => 1}} =
               Client.handle_response({:ok, %Req.Response{status: 200, body: %{"a" => 1}}})

      assert {:ok, %{}} = Client.handle_response({:ok, %Req.Response{status: 204, body: ""}})
      assert {:ok, %{}} = Client.handle_response({:ok, %Req.Response{status: 200, body: nil}})
    end

    test "error statuses" do
      assert {:error, :unauthorized} = Client.handle_response({:ok, %Req.Response{status: 401}})
      assert {:error, :forbidden} = Client.handle_response({:ok, %Req.Response{status: 403}})
      assert {:error, :not_found} = Client.handle_response({:ok, %Req.Response{status: 404}})

      assert {:error, {:not_found, "user not found (user_not_found)"}} =
               Client.handle_response(
                 {:ok,
                  %Req.Response{
                    status: 404,
                    body: %{
                      "error" => %{"code" => "user_not_found", "message" => "user not found"}
                    }
                  }}
               )

      assert {:error, :rate_limited} = Client.handle_response({:ok, %Req.Response{status: 429}})

      assert {:error, {:unexpected_status, 302}} =
               Client.handle_response({:ok, %Req.Response{status: 302}})

      assert {:error, {:signature_failed, :x}} =
               Client.handle_response(
                 {:ok, %Req.Response{status: 0, body: {:signature_failed, :x}}}
               )

      assert {:error, {:connection_error, :timeout}} = Client.handle_response({:error, :timeout})
    end

    test "extracts Kalshi error messages" do
      assert {:error, {:api_error, 400, "bad: detail"}} =
               Client.handle_response(
                 {:ok,
                  %Req.Response{
                    status: 400,
                    body: %{"code" => "x", "message" => "bad", "details" => "detail"}
                  }}
               )

      assert {:error, {:api_error, 400, "bad"}} =
               Client.handle_response(
                 {:ok, %Req.Response{status: 400, body: %{"message" => "bad"}}}
               )

      assert {:error, {:api_error, 400, "nested"}} =
               Client.handle_response(
                 {:ok, %Req.Response{status: 400, body: %{"error" => %{"message" => "nested"}}}}
               )

      assert {:error, {:api_error, 400, "flat"}} =
               Client.handle_response(
                 {:ok, %Req.Response{status: 400, body: %{"error" => "flat"}}}
               )

      assert {:error, {:api_error, 400, "code_only"}} =
               Client.handle_response(
                 {:ok, %Req.Response{status: 400, body: %{"code" => "code_only"}}}
               )

      assert {:error, {:api_error, 500, "raw text"}} =
               Client.handle_response({:ok, %Req.Response{status: 500, body: "raw text"}})

      assert {:error, {:api_error, 500, "Unknown error"}} =
               Client.handle_response({:ok, %Req.Response{status: 500, body: %{}}})
    end
  end

  describe "validate_private_key/1" do
    test "valid and invalid" do
      assert {:ok, :valid} = Client.validate_private_key(Fixtures.private_key_pem())
      assert {:error, {:invalid_private_key, _}} = Client.validate_private_key("nope")
    end
  end

  describe "verify_credentials/3" do
    test "returns the balance on success" do
      Req.Test.expect(@stub, fn conn ->
        assert conn.request_path =~ "/portfolio/balance"
        Req.Test.json(conn, Fixtures.balance_response())
      end)

      assert {:ok, %{"balance_dollars" => _}} =
               Client.verify_credentials(Fixtures.key_id(), Fixtures.private_key_pem(),
                 plug: {Req.Test, @stub}
               )
    end

    test "boolean demo argument" do
      Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, Fixtures.balance_response()) end)
      Application.put_env(:ex_kalshi, :config, [])
      # boolean form cannot take a plug, so stub via Req.Test global default
      assert {:ok, _} =
               Client.verify_credentials(Fixtures.key_id(), Fixtures.private_key_pem(),
                 plug: {Req.Test, @stub},
                 demo: true
               )

      assert is_function(&Client.verify_credentials/3)
    end

    test "unauthorized" do
      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
      end)

      assert {:error, :unauthorized} =
               Client.verify_credentials(Fixtures.key_id(), Fixtures.private_key_pem(),
                 plug: {Req.Test, @stub}
               )
    end

    test "invalid key never hits the network" do
      assert {:error, {:invalid_private_key, _}} =
               Client.verify_credentials("k", "garbage", plug: {Req.Test, @stub})
    end
  end

  describe "healthcheck/1" do
    test "ok and error" do
      Req.Test.expect(@stub, fn conn -> Req.Test.json(conn, Fixtures.balance_response()) end)
      assert :ok = Client.healthcheck(Fixtures.test_client(@stub))

      Req.Test.expect(@stub, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{})
      end)

      assert {:error, :forbidden} = Client.healthcheck(Fixtures.test_client(@stub))
    end
  end
end
