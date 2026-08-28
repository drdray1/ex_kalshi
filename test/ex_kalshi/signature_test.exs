defmodule ExKalshi.SignatureTest do
  use ExUnit.Case, async: true

  alias ExKalshi.Fixtures
  alias ExKalshi.Signature

  doctest ExKalshi.Signature, only: [message: 3, strip_query: 1]

  describe "parse_private_key/1" do
    test "parses PKCS#1 RSA PEM" do
      assert {:ok, {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _}} =
               Signature.parse_private_key(Fixtures.private_key_pem())
    end

    test "parses PKCS#8 PEM" do
      assert {:ok, key} = Signature.parse_private_key(Fixtures.pkcs8_private_key_pem())
      assert key == Fixtures.rsa_key()
    end

    test "normalises escaped newlines" do
      assert {:ok, key} = Signature.parse_private_key(Fixtures.escaped_private_key_pem())
      assert key == Fixtures.rsa_key()
    end

    test "rejects garbage" do
      assert {:error, {:invalid_private_key, _}} = Signature.parse_private_key("nope")
    end

    test "rejects a corrupted PEM body" do
      assert {:error, {:invalid_private_key, _}} =
               Signature.parse_private_key(Fixtures.invalid_pem())
    end

    test "rejects non-RSA keys" do
      assert {:error, {:invalid_private_key, msg}} =
               Signature.parse_private_key(Fixtures.ec_private_key_pem())

      assert msg =~ "ECPrivateKey"
    end

    test "rejects non-strings" do
      assert {:error, {:invalid_private_key, _}} = Signature.parse_private_key(nil)
    end
  end

  describe "sign/4 and verify/5" do
    test "produces a verifiable RSA-PSS signature over ts + METHOD + path" do
      key = Fixtures.rsa_key()
      sig = Signature.sign(key, 1_700_000_000_000, "get", "/trade-api/v2/portfolio/balance")

      assert Signature.verify(
               Fixtures.public_key(),
               1_700_000_000_000,
               "GET",
               "/trade-api/v2/portfolio/balance",
               sig
             )

      refute Signature.verify(
               Fixtures.public_key(),
               1_700_000_000_001,
               "GET",
               "/trade-api/v2/portfolio/balance",
               sig
             )

      refute Signature.verify(
               Fixtures.public_key(),
               1_700_000_000_000,
               "POST",
               "/trade-api/v2/portfolio/balance",
               sig
             )
    end

    test "ignores the query string when signing" do
      key = Fixtures.rsa_key()
      sig = Signature.sign(key, "1", "GET", "/trade-api/v2/portfolio/orders?limit=5&cursor=x")

      assert Signature.verify(
               Fixtures.public_key(),
               "1",
               "GET",
               "/trade-api/v2/portfolio/orders",
               sig
             )
    end

    test "uses PSS with a 32-byte salt (OTP verifier agrees)" do
      key = Fixtures.rsa_key()
      sig = Signature.sign(key, 1, "GET", "/x")
      {:ok, raw} = Base.decode64(sig)

      assert :public_key.verify("1GET/x", :sha256, raw, Fixtures.public_key(),
               rsa_padding: :rsa_pkcs1_pss_padding,
               rsa_pss_saltlen: 32,
               rsa_mgf1_md: :sha256
             )
    end

    test "verify returns false for non-base64 input" do
      refute Signature.verify(Fixtures.public_key(), 1, "GET", "/x", "***")
    end
  end

  describe "headers/5" do
    test "builds the three Kalshi headers" do
      headers = Signature.headers("kid", Fixtures.rsa_key(), "GET", "/trade-api/v2/markets", 42)

      assert [
               {"KALSHI-ACCESS-KEY", "kid"},
               {"KALSHI-ACCESS-TIMESTAMP", "42"},
               {"KALSHI-ACCESS-SIGNATURE", sig}
             ] = headers

      assert Signature.verify(Fixtures.public_key(), 42, "GET", "/trade-api/v2/markets", sig)
    end

    test "defaults the timestamp to now in milliseconds" do
      [_, {"KALSHI-ACCESS-TIMESTAMP", ts}, _] =
        Signature.headers("kid", Fixtures.rsa_key(), "GET", "/x")

      assert abs(String.to_integer(ts) - System.system_time(:millisecond)) < 5_000
    end
  end

  test "timestamp_ms/0 is milliseconds" do
    assert_in_delta Signature.timestamp_ms(), System.system_time(:millisecond), 1_000
  end
end
