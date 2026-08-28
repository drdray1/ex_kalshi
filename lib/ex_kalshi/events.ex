defmodule ExKalshi.Events do
  @moduledoc """
  Kalshi Trade API - Events (a group of related markets under a series).

  Public endpoints.
  """

  alias ExKalshi.{Client, Query}

  @type client :: Req.Request.t()
  @type response :: {:ok, map()} | {:error, term()}

  @list_keys [
    :limit,
    :cursor,
    :status,
    :series_ticker,
    :tickers,
    :with_nested_markets,
    :with_milestones,
    :min_close_ts,
    :min_updated_ts
  ]

  @doc """
  `GET /events`

  ## Options

    - `:limit` - 1..200 (default 200)
    - `:cursor`
    - `:status` - `"unopened" | "open" | "closed" | "settled"`
    - `:series_ticker`
    - `:tickers` - list or comma-separated event tickers
    - `:with_nested_markets` - include each event's markets (default false)
    - `:with_milestones`, `:min_close_ts`, `:min_updated_ts`
  """
  @spec list_events(client(), keyword()) :: response()
  def list_events(client, opts \\ []) do
    opts = Keyword.update(opts, :tickers, nil, &Query.csv/1)

    client
    |> Req.get(url: Query.url("/events", opts, @list_keys))
    |> Client.handle_response()
  end

  @doc """
  `GET /events/{event_ticker}`

  ## Options

    - `:with_nested_markets` - include the event's markets
  """
  @spec get_event(client(), String.t(), keyword()) :: response()
  def get_event(client, event_ticker, opts \\ []) do
    client
    |> Req.get(url: Query.url("/events/#{event_ticker}", opts, [:with_nested_markets]))
    |> Client.handle_response()
  end

  @doc "Extracts the event list from a `list_events/2` response."
  @spec extract_events(map()) :: [map()]
  def extract_events(%{"events" => events}) when is_list(events), do: events
  def extract_events(_), do: []

  @doc "Extracts the event from a `get_event/3` response."
  @spec extract_event(map()) :: map() | nil
  def extract_event(%{"event" => %{} = event}), do: event
  def extract_event(_), do: nil

  @doc "Extracts nested markets from an event (or a `get_event/3` response)."
  @spec extract_markets(map()) :: [map()]
  def extract_markets(%{"markets" => markets}) when is_list(markets), do: markets
  def extract_markets(%{"event" => %{"markets" => markets}}) when is_list(markets), do: markets
  def extract_markets(_), do: []
end
