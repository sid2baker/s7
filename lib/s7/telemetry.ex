defmodule S7.Telemetry do
  @moduledoc """
  Telemetry events emitted by an S7 connection.

  Durations use `System.monotonic_time/0` native units. Event metadata never
  contains addresses, values, encoded payloads, TSAPs, or credentials.
  """

  @events [
    [:s7, :connection, :connected],
    [:s7, :connection, :disconnected],
    [:s7, :connection, :reconnect_scheduled],
    [:s7, :request, :queued],
    [:s7, :request, :rejected],
    [:s7, :request, :start],
    [:s7, :request, :stop],
    [:s7, :userdata, :unhandled]
  ]

  @doc """
  Returns the stable event names emitted by this version.
  """
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc """
  Describes fields intentionally excluded from telemetry metadata.
  """
  @spec excluded_metadata() :: [atom()]
  def excluded_metadata,
    do: [:address, :value, :payload, :src_tsap, :dst_tsap, :credentials]

  @doc false
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata)
      when event in @events and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc false
  @spec monotonic_time() :: integer()
  def monotonic_time, do: System.monotonic_time()

  @doc false
  @spec duration(integer()) :: non_neg_integer()
  def duration(start_time), do: max(monotonic_time() - start_time, 0)
end
