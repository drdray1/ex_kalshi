defmodule ExKalshi.WebSocket.Client do
  @moduledoc """
  Thin WebSockex wrapper that forwards frames to a parent process.

      {:ok, pid} = ExKalshi.WebSocket.Client.start_link(url, self(), extra_headers: headers)
      ExKalshi.WebSocket.Client.send_message(pid, %{"id" => 1, "cmd" => "subscribe", ...})

  The parent receives:

  - `{:stream_connected, pid}`
  - `{:stream_message, pid, text}`
  - `{:stream_binary, pid, binary}`
  - `{:stream_disconnected, pid, reason}`

  Kalshi pings every 10 seconds with body `heartbeat`; ping frames are
  answered with a pong automatically.
  """

  use WebSockex

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:parent_pid, :connected]
  end

  @doc """
  Opens the socket. `opts` may include `:extra_headers` (auth headers for the
  handshake) plus any `WebSockex.start_link/4` option.
  """
  @spec start_link(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, parent_pid, opts \\ []) do
    state = %State{parent_pid: parent_pid, connected: false}

    websockex_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put_new(:handle_initial_conn_failure, true)

    WebSockex.start_link(url, __MODULE__, state, websockex_opts)
  end

  @doc "JSON-encodes and sends a command map."
  @spec send_message(pid(), map()) :: :ok | {:error, term()}
  def send_message(pid, message) when is_map(message) do
    case Jason.encode(message) do
      {:ok, json} -> WebSockex.send_frame(pid, {:text, json})
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  @doc "Sends a raw text frame."
  @spec send_text(pid(), String.t()) :: :ok | {:error, term()}
  def send_text(pid, text) when is_binary(text), do: WebSockex.send_frame(pid, {:text, text})

  @doc "Closes the socket."
  @spec close(pid()) :: :ok
  def close(pid), do: WebSockex.cast(pid, :close)

  # ============================================================================
  # WebSockex Callbacks
  # ============================================================================

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.debug("[ExKalshi.WebSocket.Client] Connected")
    send(state.parent_pid, {:stream_connected, self()})
    {:ok, %{state | connected: true}}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    send(state.parent_pid, {:stream_message, self(), msg})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:binary, msg}, state) do
    send(state.parent_pid, {:stream_binary, self(), msg})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:ping, msg}, state), do: {:reply, {:pong, msg}, state}

  @impl WebSockex
  def handle_frame({:pong, _msg}, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(disconnect_map, state) do
    reason = disconnect_map[:reason] || :unknown
    Logger.warning("[ExKalshi.WebSocket.Client] Disconnected: #{inspect(reason)}")
    send(state.parent_pid, {:stream_disconnected, self(), reason})
    {:ok, %{state | connected: false}}
  end

  @impl WebSockex
  def handle_cast(:close, state), do: {:close, state}

  @impl WebSockex
  def handle_cast({:send, frame}, state), do: {:reply, frame, state}

  @impl WebSockex
  def handle_info(msg, state) do
    Logger.debug("[ExKalshi.WebSocket.Client] Unexpected info: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSockex
  def terminate(reason, state) do
    if state.connected, do: send(state.parent_pid, {:stream_disconnected, self(), reason})
    :ok
  end
end
