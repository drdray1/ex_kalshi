defmodule ExKalshi.WebSocket.Connection do
  @moduledoc """
  GenServer managing one Kalshi WebSocket connection.

  Kalshi exposes a single endpoint for public market data and private user
  channels, authenticated once at the handshake. This process:

  - opens the socket lazily (on the first `subscribe/3`) with fresh auth headers
  - tracks subscriptions and replays them after a reconnect
  - maps server subscription ids (`sid`) back to channels
  - watches per-`sid` sequence numbers and resubscribes on a gap
  - reconnects with exponential backoff (1s → 30s, up to 10 attempts)
  - fans parsed events out to subscriber processes

  ## Usage

      {:ok, pid} = ExKalshi.WebSocket.Connection.start_link(
        key_id: "key-id",
        private_key_pem: pem,
        demo: true
      )

      ExKalshi.WebSocket.Connection.add_subscriber(pid, self())
      ExKalshi.WebSocket.Connection.subscribe(pid, [:ticker, :orderbook_delta], ["KXBTC15M-26AUG272300-00"])
      ExKalshi.WebSocket.Connection.subscribe(pid, [:fill, :user_orders])

      # You receive:
      # {:kalshi_event, :ticker, %ExKalshi.WebSocket.TickerEvent{}}
      # {:kalshi_event, :fill, %ExKalshi.WebSocket.FillEvent{}}

  Omit `:key_id`/`:private_key_pem` for an unauthenticated public-data
  connection (`ticker`, `trade`, `market_lifecycle_v2`).
  """

  use GenServer

  require Logger

  alias ExKalshi.WebSocket
  alias ExKalshi.WebSocket.Client, as: StreamClient

  @reconnect_base_delay_ms 1_000
  @reconnect_max_delay_ms 30_000
  @max_reconnect_attempts 10
  @data_types [
    :orderbook_snapshot,
    :orderbook_delta,
    :ticker,
    :trade,
    :fill,
    :user_orders,
    :market_lifecycle,
    :unknown
  ]

  defmodule State do
    @moduledoc false
    defstruct [
      :key_id,
      :private_key_pem,
      :demo,
      :websocket_pid,
      :status,
      desired: [],
      pending: %{},
      sids: %{},
      next_id: 1,
      subscribers: MapSet.new(),
      reconnect_attempts: 0,
      reconnect_timer: nil,
      subscribe_timer: nil
    ]

    @type status :: :disconnected | :connecting | :connected | :reconnecting
    @type subscription :: {[String.t()], [String.t()]}

    @type t :: %__MODULE__{
            key_id: String.t() | nil,
            private_key_pem: String.t() | nil,
            demo: boolean(),
            websocket_pid: pid() | nil,
            status: status(),
            desired: [subscription()],
            pending: %{integer() => subscription()},
            sids: %{
              integer() => %{channel: String.t(), tickers: [String.t()], seq: integer() | nil}
            },
            next_id: pos_integer(),
            subscribers: MapSet.t(pid()),
            reconnect_attempts: non_neg_integer(),
            reconnect_timer: reference() | nil,
            subscribe_timer: reference() | nil
          }
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts a Connection.

  ## Options

    - `:key_id`, `:private_key_pem` - credentials; omit both for a public connection
    - `:demo` - connect to the demo exchange (default false)
    - `:name` - process registration
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    init_args = %{
      key_id: Keyword.get(opts, :key_id),
      private_key_pem: Keyword.get(opts, :private_key_pem),
      demo: Keyword.get(opts, :demo, false)
    }

    if (init_args.key_id && !init_args.private_key_pem) ||
         (!init_args.key_id && init_args.private_key_pem) do
      raise ArgumentError, ":key_id and :private_key_pem must be given together"
    end

    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_args, gen_opts)
  end

  @doc """
  Subscribes to `channels` for `market_tickers` (empty list = all markets /
  account-wide). Connects if not yet connected. Raises on unknown channels.
  """
  @spec subscribe(GenServer.server(), [atom() | String.t()], [String.t()]) :: :ok
  def subscribe(server, channels, market_tickers \\ [])
      when is_list(channels) and is_list(market_tickers) do
    GenServer.call(server, {:subscribe, WebSocket.validate_channels!(channels), market_tickers})
  end

  @doc "Unsubscribes the subscription created with the same `channels`/`market_tickers`."
  @spec unsubscribe(GenServer.server(), [atom() | String.t()], [String.t()]) :: :ok
  def unsubscribe(server, channels, market_tickers \\ []) do
    GenServer.call(server, {:unsubscribe, Enum.map(channels, &to_string/1), market_tickers})
  end

  @doc "Registers `pid` to receive `{:kalshi_event, type, event}` messages."
  @spec add_subscriber(GenServer.server(), pid()) :: :ok
  def add_subscriber(server, pid) when is_pid(pid),
    do: GenServer.cast(server, {:add_subscriber, pid})

  @doc "Stops delivering events to `pid`."
  @spec remove_subscriber(GenServer.server(), pid()) :: :ok
  def remove_subscriber(server, pid) when is_pid(pid),
    do: GenServer.cast(server, {:remove_subscriber, pid})

  @doc "Returns `:disconnected | :connecting | :connected | :reconnecting`."
  @spec get_status(GenServer.server()) :: State.status()
  def get_status(server), do: GenServer.call(server, :get_status)

  @doc "Returns `%{status, subscriptions, sids, subscriber_count, authenticated, demo}`."
  @spec get_info(GenServer.server()) :: map()
  def get_info(server), do: GenServer.call(server, :get_info)

  @doc "Drops the socket and reconnects."
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server), do: GenServer.cast(server, :reconnect)

  @doc "Stops the connection."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(%{key_id: key_id, private_key_pem: pem, demo: demo}) do
    {:ok, %State{key_id: key_id, private_key_pem: pem, demo: demo, status: :disconnected}}
  end

  @impl GenServer
  def handle_call({:subscribe, channels, tickers}, _from, state) do
    sub = {channels, tickers}

    if sub in state.desired do
      {:reply, :ok, state}
    else
      state = %{state | desired: state.desired ++ [sub]}
      state = if connected?(state), do: send_subscribe(state, sub), else: state
      {:reply, :ok, maybe_connect(state)}
    end
  end

  @impl GenServer
  def handle_call({:unsubscribe, channels, tickers}, _from, state) do
    sub = {channels, tickers}
    state = %{state | desired: List.delete(state.desired, sub)}

    sids =
      state.sids
      |> Enum.filter(fn {_sid, %{channel: ch, tickers: t}} -> ch in channels and t == tickers end)
      |> Enum.map(fn {sid, _} -> sid end)

    state =
      if sids != [] and connected?(state) do
        {id, state} = next_id(state)
        StreamClient.send_message(state.websocket_pid, WebSocket.unsubscribe(id, sids))
        %{state | sids: Map.drop(state.sids, sids)}
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:get_status, _from, state), do: {:reply, state.status, state}

  @impl GenServer
  def handle_call(:get_info, _from, state) do
    info = %{
      status: state.status,
      subscriptions: state.desired,
      sids: state.sids,
      subscriber_count: MapSet.size(state.subscribers),
      authenticated: not is_nil(state.key_id),
      demo: state.demo
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:add_subscriber, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast({:remove_subscriber, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_cast(:reconnect, state) do
    {:noreply, state |> disconnect() |> schedule_reconnect()}
  end

  @impl GenServer
  def handle_info({:stream_connected, ws_pid}, %{websocket_pid: ws_pid} = state) do
    Logger.info("[ExKalshi.WebSocket.Connection] Connected")
    state = %{state | status: :connected, reconnect_attempts: 0, sids: %{}, pending: %{}}
    timer = Process.send_after(self(), :send_subscriptions, 0)
    {:noreply, %{state | subscribe_timer: timer}}
  end

  @impl GenServer
  def handle_info(:send_subscriptions, state) do
    state = %{state | subscribe_timer: nil}

    state =
      if connected?(state),
        do: Enum.reduce(state.desired, state, &send_subscribe(&2, &1)),
        else: state

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:stream_message, ws_pid, raw}, %{websocket_pid: ws_pid} = state) do
    state =
      case WebSocket.parse_message(raw) do
        {:ok, type, event} ->
          handle_event(type, event, state)

        {:error, reason} ->
          Logger.debug("[ExKalshi.WebSocket.Connection] Unparseable message: #{inspect(reason)}")
          state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:stream_binary, _ws_pid, _bin}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:stream_disconnected, ws_pid, reason}, %{websocket_pid: ws_pid} = state) do
    Logger.warning("[ExKalshi.WebSocket.Connection] Disconnected: #{inspect(reason)}")
    state = %{state | websocket_pid: nil, status: :disconnected, sids: %{}, pending: %{}}
    state = cancel_timer(state, :subscribe_timer)
    {:noreply, schedule_reconnect(state)}
  end

  @impl GenServer
  def handle_info(:reconnect, state) do
    Logger.info(
      "[ExKalshi.WebSocket.Connection] Reconnecting (attempt #{state.reconnect_attempts})"
    )

    {:noreply, do_connect(%{state | reconnect_timer: nil})}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("[ExKalshi.WebSocket.Connection] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    state = cancel_timer(state, :reconnect_timer)
    state = cancel_timer(state, :subscribe_timer)

    if state.websocket_pid do
      if connected?(state) and map_size(state.sids) > 0 do
        {id, _} = next_id(state)

        StreamClient.send_message(
          state.websocket_pid,
          WebSocket.unsubscribe(id, Map.keys(state.sids))
        )

        Process.sleep(50)
      end

      StreamClient.close(state.websocket_pid)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp handle_event(
         :subscribed,
         %WebSocket.SubscribedEvent{id: id, sid: sid, channel: channel},
         state
       ) do
    {tickers, pending} =
      case Map.pop(state.pending, id) do
        {{_channels, tickers}, pending} -> {tickers, pending}
        {nil, pending} -> {[], pending}
      end

    # A multi-channel subscribe answers once per channel with the same id, so
    # keep the pending entry until every channel has reported in.
    pending =
      case state.pending[id] do
        {channels, t} when length(channels) > 1 ->
          Map.put(pending, id, {List.delete(channels, channel), t})

        _ ->
          pending
      end

    Logger.info("[ExKalshi.WebSocket.Connection] Subscribed #{channel} (sid #{sid})")

    %{
      state
      | pending: pending,
        sids: Map.put(state.sids, sid, %{channel: channel, tickers: tickers, seq: nil})
    }
  end

  defp handle_event(:error, %WebSocket.ErrorEvent{} = event, state) do
    Logger.error(
      "[ExKalshi.WebSocket.Connection] Server error #{inspect(event.code)}: #{event.message}"
    )

    broadcast(state, :error, event)
    %{state | pending: Map.delete(state.pending, event.id)}
  end

  defp handle_event(:ok, %WebSocket.OkEvent{}, state), do: state
  defp handle_event(:subscriptions, %WebSocket.SubscriptionsEvent{}, state), do: state

  defp handle_event(type, event, state) when type in @data_types do
    state = track_seq(state, Map.get(event, :sid), Map.get(event, :seq))
    broadcast(state, type, event)
    state
  end

  defp handle_event(_type, _event, state), do: state

  defp track_seq(state, nil, _seq), do: state
  defp track_seq(state, _sid, nil), do: state

  defp track_seq(state, sid, seq) do
    case state.sids[sid] do
      nil ->
        state

      %{seq: last} = entry when is_integer(last) and seq > last + 1 ->
        Logger.warning(
          "[ExKalshi.WebSocket.Connection] Sequence gap on sid #{sid}: #{last} -> #{seq}; resubscribing"
        )

        resubscribe(state, sid, entry)

      entry ->
        %{state | sids: Map.put(state.sids, sid, %{entry | seq: seq})}
    end
  end

  defp resubscribe(state, sid, %{channel: channel, tickers: tickers}) do
    {id, state} = next_id(state)
    StreamClient.send_message(state.websocket_pid, WebSocket.unsubscribe(id, [sid]))
    state = %{state | sids: Map.delete(state.sids, sid)}
    send_subscribe(state, {[channel], tickers})
  end

  defp send_subscribe(state, {channels, tickers} = sub) do
    {id, state} = next_id(state)
    StreamClient.send_message(state.websocket_pid, WebSocket.subscribe(id, channels, tickers))
    %{state | pending: Map.put(state.pending, id, sub)}
  end

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp connected?(state), do: state.status == :connected and not is_nil(state.websocket_pid)

  defp maybe_connect(%{status: status} = state)
       when status in [:connected, :connecting, :reconnecting], do: state

  defp maybe_connect(%{desired: []} = state), do: state
  defp maybe_connect(state), do: do_connect(state)

  defp do_connect(state) do
    state = %{state | status: :connecting}

    with {:ok, headers} <- auth_headers(state),
         {:ok, ws_pid} <-
           StreamClient.start_link(WebSocket.websocket_url(state.demo), self(),
             extra_headers: headers
           ) do
      %{state | websocket_pid: ws_pid}
    else
      {:error, reason} ->
        Logger.error("[ExKalshi.WebSocket.Connection] Connect failed: #{inspect(reason)}")
        schedule_reconnect(%{state | status: :disconnected})
    end
  end

  defp auth_headers(%{key_id: nil}), do: {:ok, []}

  defp auth_headers(%{key_id: key_id, private_key_pem: pem}),
    do: WebSocket.handshake_headers(key_id, pem)

  defp broadcast(state, type, event) do
    Enum.each(state.subscribers, &send(&1, {:kalshi_event, type, event}))
  end

  defp schedule_reconnect(%{reconnect_attempts: attempts} = state)
       when attempts >= @max_reconnect_attempts do
    Logger.error("[ExKalshi.WebSocket.Connection] Max reconnect attempts reached")
    %{state | status: :disconnected}
  end

  defp schedule_reconnect(state) do
    state = cancel_timer(state, :reconnect_timer)
    delay = backoff_delay(state.reconnect_attempts)
    timer = Process.send_after(self(), :reconnect, delay)
    Logger.info("[ExKalshi.WebSocket.Connection] Reconnect in #{delay}ms")

    %{
      state
      | reconnect_timer: timer,
        reconnect_attempts: state.reconnect_attempts + 1,
        status: :reconnecting
    }
  end

  @doc false
  def backoff_delay(attempts) do
    min(round(@reconnect_base_delay_ms * :math.pow(2, attempts)), @reconnect_max_delay_ms)
  end

  defp disconnect(state) do
    state = cancel_timer(state, :reconnect_timer)
    state = cancel_timer(state, :subscribe_timer)
    if state.websocket_pid, do: StreamClient.close(state.websocket_pid)
    %{state | websocket_pid: nil, status: :disconnected, sids: %{}, pending: %{}}
  end

  defp cancel_timer(state, field) do
    case Map.get(state, field) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, field, nil)
    end
  end
end
