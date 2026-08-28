defmodule ExKalshi.Signature do
  @moduledoc """
  RSA-PSS request signing for the Kalshi Trade API.

  Every authenticated request carries three headers:

  - `KALSHI-ACCESS-KEY` — the API key ID
  - `KALSHI-ACCESS-TIMESTAMP` — Unix time in milliseconds
  - `KALSHI-ACCESS-SIGNATURE` — base64 of the RSA-PSS/SHA-256 signature over
    `timestamp <> METHOD <> path`

  The signed path is the full request path from the host root, **without**
  the query string — e.g. `/trade-api/v2/portfolio/orders`, never
  `/trade-api/v2/portfolio/orders?limit=5`. WebSocket handshakes sign
  `GET` + `/trade-api/ws/v2`.

  The private key is the RSA key Kalshi hands out when an API key is
  created. Both `-----BEGIN RSA PRIVATE KEY-----` (PKCS#1) and
  `-----BEGIN PRIVATE KEY-----` (PKCS#8) encodings are accepted.
  """

  @type rsa_key :: :public_key.rsa_private_key()

  @pss_opts [
    rsa_padding: :rsa_pkcs1_pss_padding,
    rsa_pss_saltlen: 32,
    rsa_mgf1_md: :sha256
  ]

  @doc """
  Parses a PEM-encoded RSA private key.

  Literal `\\n` sequences are normalised to newlines so keys pasted from an
  environment variable work unchanged.
  """
  @spec parse_private_key(String.t()) :: {:ok, rsa_key()} | {:error, term()}
  def parse_private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(normalize_pem(pem)) do
      [entry | _] -> decode_entry(entry)
      [] -> {:error, {:invalid_private_key, "no PEM entry found"}}
    end
  rescue
    e -> {:error, {:invalid_private_key, Exception.message(e)}}
  end

  def parse_private_key(_), do: {:error, {:invalid_private_key, "key must be a string"}}

  @doc """
  Signs `timestamp <> METHOD <> path` with RSA-PSS/SHA-256 and returns the
  base64-encoded signature.

  `path` may contain a query string; it is stripped before signing.
  """
  @spec sign(rsa_key(), String.t() | integer(), String.t(), String.t()) :: String.t()
  def sign(key, timestamp, method, path) do
    timestamp
    |> message(method, path)
    |> :public_key.sign(:sha256, key, @pss_opts)
    |> Base.encode64()
  end

  @doc """
  Verifies a base64 signature produced by `sign/4`. Mostly useful in tests.
  """
  @spec verify(
          :public_key.rsa_public_key(),
          String.t() | integer(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          boolean()
  def verify(public_key, timestamp, method, path, signature) do
    case Base.decode64(signature) do
      {:ok, raw} ->
        :public_key.verify(message(timestamp, method, path), :sha256, raw, public_key, @pss_opts)

      :error ->
        false
    end
  end

  @doc """
  Builds the three Kalshi auth headers for a request.

  ## Examples

      iex> {:ok, key} = ExKalshi.Signature.parse_private_key(pem)
      iex> ExKalshi.Signature.headers("key-id", key, "GET", "/trade-api/v2/portfolio/balance")
      [
        {"KALSHI-ACCESS-KEY", "key-id"},
        {"KALSHI-ACCESS-TIMESTAMP", "1700000000000"},
        {"KALSHI-ACCESS-SIGNATURE", "..."}
      ]
  """
  @spec headers(String.t(), rsa_key(), String.t(), String.t(), integer() | nil) ::
          [{String.t(), String.t()}]
  def headers(key_id, key, method, path, timestamp \\ nil) do
    ts = timestamp || timestamp_ms()

    [
      {"KALSHI-ACCESS-KEY", key_id},
      {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts)},
      {"KALSHI-ACCESS-SIGNATURE", sign(key, ts, method, path)}
    ]
  end

  @doc "Current Unix time in milliseconds."
  @spec timestamp_ms() :: integer()
  def timestamp_ms, do: System.system_time(:millisecond)

  @doc """
  Returns the exact byte string that gets signed.

      iex> ExKalshi.Signature.message(1700000000000, "get", "/trade-api/v2/markets?limit=1")
      "1700000000000GET/trade-api/v2/markets"
  """
  @spec message(String.t() | integer(), String.t(), String.t()) :: String.t()
  def message(timestamp, method, path) do
    to_string(timestamp) <> String.upcase(method) <> strip_query(path)
  end

  @doc """
  Removes the query string (and fragment) from a path.

      iex> ExKalshi.Signature.strip_query("/a/b?x=1")
      "/a/b"
  """
  @spec strip_query(String.t()) :: String.t()
  def strip_query(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("#", parts: 2)
    |> hd()
  end

  @doc "Derives the RSA public key from a private key (for verification in tests)."
  @spec public_key(rsa_key()) :: :public_key.rsa_public_key()
  def public_key(private_key) do
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private_key
    {:RSAPublicKey, modulus, exponent}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp decode_entry({:RSAPrivateKey, _, _} = entry) do
    {:ok, :public_key.pem_entry_decode(entry)}
  end

  defp decode_entry({:PrivateKeyInfo, _, _} = entry) do
    case :public_key.pem_entry_decode(entry) do
      {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key ->
        {:ok, key}

      {:PrivateKeyInfo, _, {:PrivateKeyInfo_privateKeyAlgorithm, oid, _}, der, _} ->
        decode_pkcs8_der(oid, der)

      other ->
        {:error, {:invalid_private_key, "unsupported key type #{inspect(elem(other, 0))}"}}
    end
  end

  defp decode_entry({type, _, _}) do
    {:error, {:invalid_private_key, "unsupported PEM entry #{inspect(type)}"}}
  end

  # OTP < 26 leaves PKCS#8 wrapped; unwrap the inner RSAPrivateKey manually.
  defp decode_pkcs8_der({1, 2, 840, 113_549, 1, 1, 1}, der) when is_binary(der) do
    {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
  end

  defp decode_pkcs8_der(oid, _der) do
    {:error, {:invalid_private_key, "not an RSA key (OID #{inspect(oid)})"}}
  end

  defp normalize_pem(pem) do
    pem
    |> String.replace("\\n", "\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end
end
