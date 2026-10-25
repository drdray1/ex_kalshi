# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0, minor version bumps may include breaking changes.

## [0.1.3] - 2026-10-24

### Changed

- Updated dependencies to their latest versions allowed by `mix.exs` (`mix.lock` only).

## [0.1.2] - 2026-08-30

### Changed
- `Client.handle_response/1`: a 404 whose body names a Kalshi error code now
  returns `{:error, {:not_found, "message (code)"}}` (e.g. `user_not_found` when
  an account that has not finished onboarding creates an order); a bare 404 is
  still `{:error, :not_found}`.

## [0.1.1] - 2026-08-30

### Changed

- `ExKalshi.Client.verify_credentials/3` returns `{:error, {:unauthorized, detail}}` with Kalshi's
  authentication detail (e.g. `NOT_FOUND` when the key id belongs to the other exchange)

## [0.1.0] - 2026-08-27

### Added

- `ExKalshi.Client` / `ExKalshi.Auth` / `ExKalshi.Signature` — Req-based client with
  RSA-PSS request signing (`KALSHI-ACCESS-*` headers), production and demo environments
- REST: `ExKalshi.Exchange`, `Markets` (incl. orderbook, trades, candlesticks, auto-pagination),
  `Events`, `Series`, `Orders` (V2 create / batch / cancel / amend / decrease / reads),
  `Portfolio` (balance, positions, fills, settlements)
- `ExKalshi.Predictions` — YES/NO order helpers, price conversion, quadratic fee estimate,
  orderbook best-price helpers, position side, Coinbase `-KALSHI` product-id bridge
- `ExKalshi.Orderbook` — parsed bids-only book with delta application
- WebSocket: `ExKalshi.WebSocket` (commands, typed events, parsing), `WebSocket.Client`
  (WebSockex wrapper), `WebSocket.Connection` (GenServer with handshake auth, sid/seq
  tracking, gap resubscribe, reconnect backoff, subscriber fan-out)
