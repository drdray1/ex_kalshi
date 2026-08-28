defmodule ExKalshi.Exchange do
  @moduledoc """
  Kalshi Trade API - Exchange status and schedule.

  Both endpoints are public; an `ExKalshi.Client.public/1` client works.
  """

  alias ExKalshi.Client

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @doc """
  `GET /exchange/status` — whether the exchange and trading are active.

      iex> ExKalshi.Exchange.status(client)
      {:ok, %{"exchange_active" => true, "trading_active" => true}}
  """
  @spec status(client()) :: response()
  def status(client) do
    client
    |> Req.get(url: "/exchange/status")
    |> Client.handle_response()
  end

  @doc """
  `GET /exchange/schedule` — standard trading hours (ET) and maintenance windows.
  """
  @spec schedule(client()) :: response()
  def schedule(client) do
    client
    |> Req.get(url: "/exchange/schedule")
    |> Client.handle_response()
  end

  @doc "True when both `exchange_active` and `trading_active` are set."
  @spec trading_active?(map()) :: boolean()
  def trading_active?(%{"exchange_active" => true, "trading_active" => true}), do: true
  def trading_active?(_), do: false
end
