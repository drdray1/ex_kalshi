defmodule ExKalshi.Fixtures do
  @moduledoc """
  Shared test data: a throwaway RSA key, client builders and sample payloads.
  """

  @rsa_key :public_key.generate_key({:rsa, 2048, 65_537})
  @pkcs1_pem :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, @rsa_key)])
  @pkcs8_pem :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, @rsa_key)])

  @key_id "3d0d2a5b-test-key-id"

  def key_id, do: @key_id
  def rsa_key, do: @rsa_key
  def public_key, do: ExKalshi.Signature.public_key(@rsa_key)
  def private_key_pem, do: @pkcs1_pem
  def pkcs8_private_key_pem, do: @pkcs8_pem
  def invalid_pem, do: "-----BEGIN RSA PRIVATE KEY-----\nnotakey\n-----END RSA PRIVATE KEY-----"
  def escaped_private_key_pem, do: String.replace(@pkcs1_pem, "\n", "\\n")

  def ec_private_key_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  def test_client(stub_name, opts \\ []) do
    @key_id
    |> ExKalshi.Client.new(@pkcs1_pem, Keyword.put(opts, :plug, {Req.Test, stub_name}))
    |> Req.Request.merge_options(retry: false)
  end

  def public_client(stub_name, opts \\ []) do
    opts
    |> Keyword.put(:plug, {Req.Test, stub_name})
    |> ExKalshi.Client.public()
    |> Req.Request.merge_options(retry: false)
  end

  # ---------------------------------------------------------------------------
  # REST payloads
  # ---------------------------------------------------------------------------

  def exchange_status, do: %{"exchange_active" => true, "trading_active" => true}

  def market(overrides \\ %{}) do
    Map.merge(
      %{
        "ticker" => "KXBTC15M-26AUG272300-00",
        "event_ticker" => "KXBTC15M-26AUG272300",
        "series_ticker" => "KXBTC15M",
        "title" => "BTC above 110,000 at 11:00pm?",
        "status" => "open",
        "yes_bid_dollars" => "0.5500",
        "yes_ask_dollars" => "0.5700",
        "no_bid_dollars" => "0.4300",
        "no_ask_dollars" => "0.4500",
        "last_price_dollars" => "0.5600",
        "volume_fp" => "1234.00",
        "open_interest_fp" => "500.00",
        "close_time" => "2026-08-27T23:00:00Z",
        "result" => ""
      },
      overrides
    )
  end

  def markets_response(markets \\ [market()], cursor \\ ""),
    do: %{"markets" => markets, "cursor" => cursor}

  def market_response, do: %{"market" => market()}

  def orderbook_response do
    %{
      "orderbook_fp" => %{
        "yes_dollars" => [["0.5500", "100.00"], ["0.5400", "250.00"]],
        "no_dollars" => [["0.4300", "80.00"], ["0.4000", "10.00"]]
      }
    }
  end

  def trades_response do
    %{
      "trades" => [
        %{
          "trade_id" => "t-1",
          "ticker" => "KXBTC15M-26AUG272300-00",
          "count_fp" => "5.00",
          "yes_price_dollars" => "0.5600",
          "no_price_dollars" => "0.4400",
          "taker_outcome_side" => "yes",
          "created_time" => "2026-08-27T22:00:00Z"
        }
      ],
      "cursor" => ""
    }
  end

  def candlesticks_response do
    %{
      "candlesticks" => [
        %{
          "end_period_ts" => 1_756_332_000,
          "price" => %{
            "open" => "0.5000",
            "high" => "0.5800",
            "low" => "0.4900",
            "close" => "0.5600"
          },
          "volume_fp" => "42.00",
          "open_interest_fp" => "500.00"
        }
      ]
    }
  end

  def event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_ticker" => "KXBTC15M-26AUG272300",
        "series_ticker" => "KXBTC15M",
        "title" => "BTC price at 11:00pm",
        "mutually_exclusive" => false,
        "markets" => [market()]
      },
      overrides
    )
  end

  def events_response, do: %{"events" => [event()], "cursor" => ""}
  def event_response, do: %{"event" => event()}

  def series(overrides \\ %{}) do
    Map.merge(
      %{
        "ticker" => "KXBTC15M",
        "title" => "BTC 15 minute",
        "fee_type" => "quadratic",
        "fee_multiplier" => 0.07
      },
      overrides
    )
  end

  def series_list_response, do: %{"series" => [series()]}
  def series_response, do: %{"series" => series()}

  def order(overrides \\ %{}) do
    Map.merge(
      %{
        "order_id" => "o-1",
        "client_order_id" => "cid-1",
        "ticker" => "KXBTC15M-26AUG272300-00",
        "status" => "resting",
        "side" => "yes",
        "book_side" => "bid",
        "yes_price_dollars" => "0.5600",
        "initial_count_fp" => "10.00",
        "remaining_count_fp" => "10.00",
        "fill_count_fp" => "0.00"
      },
      overrides
    )
  end

  def create_order_response do
    %{
      "order_id" => "o-1",
      "client_order_id" => "cid-1",
      "fill_count" => "0.00",
      "remaining_count" => "10.00",
      "average_fill_price" => nil,
      "average_fee_paid" => nil,
      "ts_ms" => 1_756_332_000_000
    }
  end

  def cancel_order_response,
    do: %{
      "order_id" => "o-1",
      "client_order_id" => "cid-1",
      "reduced_by" => "10.00",
      "ts_ms" => 1
    }

  def orders_response, do: %{"orders" => [order()], "cursor" => ""}
  def order_response, do: %{"order" => order()}

  def balance_response,
    do: %{
      "balance" => 123_456,
      "balance_dollars" => "1234.5600",
      "portfolio_value" => 200_000,
      "updated_ts" => 1
    }

  def positions_response do
    %{
      "market_positions" => [
        %{
          "ticker" => "KXBTC15M-26AUG272300-00",
          "position_fp" => "10.00",
          "market_exposure_dollars" => "5.6000",
          "realized_pnl_dollars" => "0.0000"
        },
        %{
          "ticker" => "KXBTC15M-26AUG272300-01",
          "position_fp" => "-4.00",
          "market_exposure_dollars" => "1.8000",
          "realized_pnl_dollars" => "0.0000"
        }
      ],
      "event_positions" => [
        %{"event_ticker" => "KXBTC15M-26AUG272300", "event_exposure_dollars" => "7.4000"}
      ],
      "cursor" => ""
    }
  end

  def fills_response do
    %{
      "fills" => [
        %{
          "fill_id" => "f-1",
          "order_id" => "o-1",
          "ticker" => "KXBTC15M-26AUG272300-00",
          "count_fp" => "10.00",
          "yes_price_dollars" => "0.5600",
          "is_taker" => true,
          "fee_cost" => "0.18"
        }
      ],
      "cursor" => ""
    }
  end

  def settlements_response,
    do: %{
      "settlements" => [
        %{
          "ticker" => "KXBTC15M-26AUG272300-00",
          "market_result" => "yes",
          "revenue_dollars" => "10.0000"
        }
      ],
      "cursor" => ""
    }

  def error_body(message \\ "bad things"), do: %{"code" => "bad_request", "message" => message}

  # ---------------------------------------------------------------------------
  # WebSocket payloads
  # ---------------------------------------------------------------------------

  def ws_subscribed(id \\ 1, sid \\ 7, channel \\ "ticker"),
    do: %{"id" => id, "type" => "subscribed", "msg" => %{"channel" => channel, "sid" => sid}}

  def ws_error(id \\ 1),
    do: %{"id" => id, "type" => "error", "msg" => %{"code" => 6, "msg" => "Already subscribed"}}

  def ws_ok(id \\ 2),
    do: %{
      "id" => id,
      "sid" => 7,
      "seq" => 1,
      "type" => "ok",
      "msg" => %{"market_tickers" => ["A"]}
    }

  def ws_orderbook_snapshot(sid \\ 7, seq \\ 1) do
    %{
      "type" => "orderbook_snapshot",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "market_ticker" => "KXBTC15M-26AUG272300-00",
        "market_id" => "m-1",
        "yes_dollars_fp" => [["0.0800", "300.00"], ["0.2200", "333.00"]],
        "no_dollars_fp" => [["0.5400", "20.00"], ["0.5600", "146.00"]]
      }
    }
  end

  def ws_orderbook_delta(sid \\ 7, seq \\ 2) do
    %{
      "type" => "orderbook_delta",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "market_ticker" => "KXBTC15M-26AUG272300-00",
        "market_id" => "m-1",
        "price_dollars" => "0.2200",
        "delta_fp" => "-33.00",
        "side" => "yes",
        "ts_ms" => 1_669_149_841_000
      }
    }
  end

  def ws_ticker(sid \\ 7, seq \\ 1) do
    %{
      "type" => "ticker",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "market_ticker" => "KXBTC15M-26AUG272300-00",
        "market_id" => "m-1",
        "price_dollars" => "0.480",
        "yes_bid_dollars" => "0.450",
        "yes_ask_dollars" => "0.530",
        "volume_fp" => "33896.00",
        "open_interest_fp" => "20422.00",
        "yes_bid_size_fp" => "300.00",
        "yes_ask_size_fp" => "150.00",
        "last_trade_size_fp" => "25.00",
        "ts" => 1_669_149_841,
        "ts_ms" => 1_669_149_841_000
      }
    }
  end

  def ws_trade(sid \\ 8, seq \\ 1) do
    %{
      "type" => "trade",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "market_ticker" => "KXBTC15M-26AUG272300-00",
        "trade_id" => "t-1",
        "yes_price_dollars" => "0.5600",
        "no_price_dollars" => "0.4400",
        "count_fp" => "5.00",
        "taker_side" => "yes",
        "ts_ms" => 1
      }
    }
  end

  def ws_fill(sid \\ 9, seq \\ 1) do
    %{
      "type" => "fill",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "trade_id" => "d91bc706",
        "order_id" => "ee587a1c",
        "market_ticker" => "KXBTC15M-26AUG272300-00",
        "is_taker" => true,
        "side" => "yes",
        "yes_price_dollars" => "0.750",
        "count_fp" => "278.00",
        "fee_cost" => "0.00",
        "action" => "buy",
        "ts_ms" => 1_671_899_397_000,
        "post_position_fp" => "500.00",
        "client_order_id" => "cid-1",
        "subaccount" => 0
      }
    }
  end

  def ws_user_order(sid \\ 10, seq \\ 1) do
    %{
      "type" => "user_order",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{
        "order" => %{
          "order_id" => "o-1",
          "client_order_id" => "cid-1",
          "ticker" => "KXBTC15M-26AUG272300-00",
          "status" => "resting",
          "side" => "yes",
          "yes_price_dollars" => "0.5600",
          "initial_count_fp" => "10.00",
          "remaining_count_fp" => "10.00",
          "fill_count_fp" => "0.00"
        },
        "ts_ms" => 5
      }
    }
  end

  def ws_lifecycle(sid \\ 11, seq \\ 1),
    do: %{
      "type" => "market_lifecycle_v2",
      "sid" => sid,
      "seq" => seq,
      "msg" => %{"market_ticker" => "KXBTC15M-26AUG272300-00", "event_type" => "close"}
    }

  def ws_unknown,
    do: %{"type" => "pyth_value", "sid" => 12, "seq" => 1, "msg" => %{"value" => "1"}}
end
