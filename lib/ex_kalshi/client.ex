defmodule ExKalshi.Client do
  @moduledoc """
  HTTP client for the Kalshi Trade API v2.

  A client is a plain `Req.Request` — build one with `new/3` (authenticated)
  or `public/1` (unauthenticated) and pass it as the first argument to every
  API function.

  ## Environments

  | | REST | WebSocket |
  |---|---|---|
  | production | `https://external-api.kalshi.com/trade-api/v2` | `wss://external-api-ws.kalshi.com/trade-api/ws/v2` |
  | demo | `https://external-api.demo.kalshi.co/trade-api/v2` | `wss://external-api-ws.demo.kalshi.co/trade-api/ws/v2` |

  Pass `demo: true` to target the demo exchange. URLs can be overridden with
  application config:

      config :ex_kalshi, :config,
        base_url: "https://external-api.kalshi.com/trade-api/v2",
        demo_url: "https://external-api.demo.kalshi.co/trade-api/v2",
        websocket_url: "wss://external-api-ws.kalshi.com/trade-api/ws/v2",
        demo_websocket_url: "wss://external-api-ws.demo.kalshi.co/trade-api/ws/v2",
        timeout: 30_000

  ## Usage

      client = ExKalshi.Client.new("key-id", private_key_pem)
      {:ok, %{"balance_dollars" => _}} = ExKalshi.Portfolio.get_balance(client)

      public = ExKalshi.Client.public()
      {:ok, %{"exchange_active" => true}} = ExKalshi.Exchange.status(public)
  """

  require Logger

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @default_base_url "https://external-api.kalshi.com/trade-api/v2"
  @default_demo_url "https://external-api.demo.kalshi.co/trade-api/v2"
  @default_ws_url "wss://external-api-ws.kalshi.com/trade-api/ws/v2"
  @default_demo_ws_url "wss://external-api-ws.demo.kalshi.co/trade-api/ws/v2"
  @default_timeout 30_000

  @doc """
  Creates an authenticated client.

  ## Parameters

    - `key_id` - Kalshi API key ID
    - `private_key_pem` - RSA private key (PEM)

  ## Options

    - `:demo` - Use the demo exchange (default: false)
    - `:plug` - Test plug for `Req.Test` (default: nil)
  """
  @spec new(String.t(), String.t(), keyword()) :: client()
  def new(key_id, private_key_pem, opts \\ []) do
    opts
    |> public()
    |> ExKalshi.Auth.attach(key_id, private_key_pem)
  end

  @doc """
  Creates an unauthenticated client for public endpoints (exchange status,
  markets, events, series, trades). Accepts the same `:demo` and `:plug`
  options as `new/3`.
  """
  @spec public(keyword()) :: client()
  def public(opts \\ []) do
    demo = Keyword.get(opts, :demo, false)

    [
      base_url: base_url(demo),
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      receive_timeout: timeout(),
      retry: :transient,
      max_retries: 3,
      retry_delay: fn attempt -> 500 * Integer.pow(2, max(0, attempt)) end
    ]
    |> maybe_add_plug(Keyword.get(opts, :plug))
    |> Req.new()
  end

  @doc "REST base URL for the production or demo exchange."
  @spec base_url(boolean()) :: String.t()
  def base_url(demo \\ false) do
    if demo,
      do: config(:demo_url, @default_demo_url),
      else: config(:base_url, @default_base_url)
  end

  @doc "WebSocket URL for the production or demo exchange."
  @spec websocket_url(boolean()) :: String.t()
  def websocket_url(demo \\ false) do
    if demo,
      do: config(:demo_websocket_url, @default_demo_ws_url),
      else: config(:websocket_url, @default_ws_url)
  end

  @doc "Configured receive timeout in milliseconds."
  @spec timeout() :: non_neg_integer()
  def timeout, do: config(:timeout, @default_timeout)

  @doc "Checks that a private key parses. Returns `{:ok, :valid}` or `{:error, reason}`."
  @spec validate_private_key(String.t()) :: {:ok, :valid} | {:error, term()}
  def validate_private_key(private_key_pem) do
    case ExKalshi.Signature.parse_private_key(private_key_pem) do
      {:ok, _key} -> {:ok, :valid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies credentials with `GET /portfolio/balance`.

  Returns `{:ok, balance}` on success, `{:error, {:unauthorized, detail}}` when
  Kalshi rejects the key (`detail` is the exchange's reason — `"NOT_FOUND"`
  means the key id does not exist on *this* exchange: demo keys only work
  with `demo: true`, production keys without it), `{:error, :unauthorized}`
  when no detail is given, and `{:error, {:invalid_private_key, reason}}`
  when the PEM cannot be parsed.
  """
  @spec verify_credentials(String.t(), String.t(), boolean() | keyword()) :: response()
  def verify_credentials(key_id, private_key_pem, opts \\ false)

  def verify_credentials(key_id, private_key_pem, demo) when is_boolean(demo) do
    verify_credentials(key_id, private_key_pem, demo: demo)
  end

  def verify_credentials(key_id, private_key_pem, opts) when is_list(opts) do
    case validate_private_key(private_key_pem) do
      {:ok, :valid} ->
        key_id
        |> new(private_key_pem, opts)
        |> Req.get(url: "/portfolio/balance")
        |> verify_response()
        |> log_verify_failure()

      {:error, reason} ->
        Logger.error("Kalshi private key validation failed: #{inspect(reason)}")
        {:error, {:invalid_private_key, reason}}
    end
  end

  @doc "Cheap liveness check on an authenticated client."
  @spec healthcheck(client()) :: :ok | {:error, term()}
  def healthcheck(client) do
    case client |> Req.get(url: "/portfolio/balance") |> handle_response() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Normalises a Req result into `{:ok, body}` / `{:error, reason}`."
  @spec handle_response({:ok, Req.Response.t()} | {:error, term()}) :: response()
  def handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299 do
    {:ok, normalize_body(body)}
  end

  def handle_response({:ok, %Req.Response{status: 401}}), do: {:error, :unauthorized}
  def handle_response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}
  def handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  def handle_response({:ok, %Req.Response{status: 429}}), do: {:error, :rate_limited}

  def handle_response({:ok, %Req.Response{status: 0, body: {:signature_failed, reason}}}) do
    {:error, {:signature_failed, reason}}
  end

  def handle_response({:ok, %Req.Response{status: status, body: body}}) when status >= 400 do
    {:error, {:api_error, status, extract_error_message(body)}}
  end

  def handle_response({:ok, %Req.Response{status: status}}) do
    {:error, {:unexpected_status, status}}
  end

  def handle_response({:error, reason}), do: {:error, {:connection_error, reason}}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp config(key, default) do
    :ex_kalshi
    |> Application.get_env(:config, [])
    |> Keyword.get(key, default)
  end

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  # DELETE responses and a few writes come back with an empty body.
  defp normalize_body(""), do: %{}
  defp normalize_body(nil), do: %{}
  defp normalize_body(body), do: body

  # Keep Kalshi's authentication detail for the verify path only.
  defp verify_response({:ok, %Req.Response{status: 401, body: body}}) do
    case auth_detail(body) do
      nil -> {:error, :unauthorized}
      detail -> {:error, {:unauthorized, detail}}
    end
  end

  defp verify_response(result), do: handle_response(result)

  defp auth_detail(%{"error" => %{} = err}), do: auth_detail(err)

  defp auth_detail(%{"details" => details, "message" => message})
       when is_binary(details) and details != "",
       do: "#{message} (#{details})"

  defp auth_detail(%{"message" => message}) when is_binary(message) and message != "", do: message
  defp auth_detail(_), do: nil

  defp log_verify_failure({:error, reason} = result) do
    Logger.warning("Kalshi credential verification failed: #{inspect(reason)}")
    result
  end

  defp log_verify_failure(result), do: result

  # Kalshi errors look like %{"code" => "...", "message" => "...", "details" => "..."};
  # the message is the human-readable part, details (when present) refine it.
  @spec extract_error_message(term()) :: String.t()
  defp extract_error_message(%{"message" => message, "details" => details})
       when is_binary(message) and is_binary(details) and details != "",
       do: "#{message}: #{details}"

  defp extract_error_message(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp extract_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp extract_error_message(%{"error" => error}) when is_binary(error), do: error
  defp extract_error_message(%{"code" => code}) when is_binary(code), do: code
  defp extract_error_message(body) when is_binary(body) and body != "", do: body
  defp extract_error_message(_), do: "Unknown error"
end
