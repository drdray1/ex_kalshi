defmodule ExKalshi.Auth do
  @moduledoc """
  Req plugin that signs every request with Kalshi's RSA-PSS scheme.

  The key is parsed once when the plugin is attached; each request then gets
  fresh `KALSHI-ACCESS-*` headers from `ExKalshi.Signature.headers/5`.

  Typically used via `ExKalshi.Client.new/3`, but can be attached manually:

      Req.new(base_url: "https://external-api.kalshi.com/trade-api/v2")
      |> ExKalshi.Auth.attach(key_id, private_key_pem)

  A key that cannot be parsed does not raise: the request step short-circuits
  with a synthetic `status: 0` response whose body is
  `{:signature_failed, reason}`, which `ExKalshi.Client.handle_response/1`
  turns into `{:error, {:signature_failed, reason}}`.
  """

  alias ExKalshi.Signature

  @api_base_path "/trade-api/v2"

  @doc """
  Attaches Kalshi authentication to a Req request.
  """
  @spec attach(Req.Request.t(), String.t(), String.t()) :: Req.Request.t()
  def attach(request, key_id, private_key_pem) do
    parsed = Signature.parse_private_key(private_key_pem)

    request
    |> Req.Request.register_options([:kalshi_key_id, :kalshi_private_key])
    |> Req.Request.merge_options(kalshi_key_id: key_id, kalshi_private_key: parsed)
    |> Req.Request.append_request_steps(kalshi_auth: &sign_request/1)
  end

  @doc "The path prefix every REST route is signed under."
  @spec api_base_path() :: String.t()
  def api_base_path, do: @api_base_path

  @doc """
  Returns the path that gets signed for a request URL: the `/trade-api/v2`
  prefix plus the route, with the query string removed.

      iex> ExKalshi.Auth.sign_path(URI.parse("https://x/trade-api/v2/markets?limit=1"))
      "/trade-api/v2/markets"

      iex> ExKalshi.Auth.sign_path(URI.parse("/markets"))
      "/trade-api/v2/markets"
  """
  @spec sign_path(URI.t()) :: String.t()
  def sign_path(%URI{path: path}) when is_binary(path),
    do: ensure_base_path(Signature.strip_query(path))

  def sign_path(_), do: @api_base_path

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp sign_request(request) do
    key_id = request.options[:kalshi_key_id]

    case request.options[:kalshi_private_key] do
      {:ok, key} when is_binary(key_id) ->
        method = request.method |> Atom.to_string() |> String.upcase()
        headers = Signature.headers(key_id, key, method, sign_path(request.url))

        Enum.reduce(headers, request, fn {name, value}, req ->
          Req.Request.put_header(req, name, value)
        end)

      {:error, reason} ->
        {request, Req.Response.new(status: 0, body: {:signature_failed, reason})}

      _ ->
        request
    end
  end

  defp ensure_base_path(path) do
    if String.starts_with?(path, @api_base_path), do: path, else: @api_base_path <> path
  end
end
