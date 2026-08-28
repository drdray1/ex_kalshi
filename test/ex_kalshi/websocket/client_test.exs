defmodule ExKalshi.WebSocket.ClientTest do
  use ExUnit.Case, async: false
  use Mimic

  alias ExKalshi.WebSocket.Client
  alias ExKalshi.WebSocket.Client.State

  setup :verify_on_exit!

  test "start_link/3 passes headers and defaults handle_initial_conn_failure" do
    parent = self()

    expect(WebSockex, :start_link, fn url, Client, %State{parent_pid: ^parent}, opts ->
      assert url == "wss://x"
      assert opts[:extra_headers] == [{"a", "b"}]
      assert opts[:handle_initial_conn_failure] == true
      refute Keyword.has_key?(opts, :name)
      {:ok, self()}
    end)

    assert {:ok, _} =
             Client.start_link("wss://x", parent, extra_headers: [{"a", "b"}], name: :ignored)
  end

  test "send_message/2 encodes JSON; send_text/2 and close/1 delegate" do
    expect(WebSockex, :send_frame, fn _pid, {:text, json} ->
      assert Jason.decode!(json) == %{"cmd" => "x"}
      :ok
    end)

    assert :ok = Client.send_message(self(), %{"cmd" => "x"})
    assert {:error, {:encode_error, _}} = Client.send_message(self(), %{"bad" => {1, 2}})

    expect(WebSockex, :send_frame, fn _pid, {:text, "raw"} -> :ok end)
    assert :ok = Client.send_text(self(), "raw")

    expect(WebSockex, :cast, fn _pid, :close -> :ok end)
    assert :ok = Client.close(self())
  end

  test "callbacks forward to the parent" do
    state = %State{parent_pid: self(), connected: false}

    assert {:ok, %State{connected: true} = state} = Client.handle_connect(:conn, state)
    assert_receive {:stream_connected, _}

    assert {:ok, _} = Client.handle_frame({:text, "hi"}, state)
    assert_receive {:stream_message, _, "hi"}

    assert {:ok, _} = Client.handle_frame({:binary, <<1>>}, state)
    assert_receive {:stream_binary, _, <<1>>}

    assert {:reply, {:pong, "heartbeat"}, _} = Client.handle_frame({:ping, "heartbeat"}, state)
    assert {:ok, _} = Client.handle_frame({:pong, ""}, state)

    assert {:ok, %State{connected: false}} = Client.handle_disconnect(%{reason: :gone}, state)
    assert_receive {:stream_disconnected, _, :gone}

    assert {:close, _} = Client.handle_cast(:close, state)
    assert {:reply, {:text, "f"}, _} = Client.handle_cast({:send, {:text, "f"}}, state)
    assert {:ok, _} = Client.handle_info(:whatever, state)

    assert :ok = Client.terminate(:normal, state)
    assert_receive {:stream_disconnected, _, :normal}
    assert :ok = Client.terminate(:normal, %State{parent_pid: self(), connected: false})
    refute_receive {:stream_disconnected, _, _}
  end
end
