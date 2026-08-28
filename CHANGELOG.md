# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0, minor version bumps may include breaking changes.

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
