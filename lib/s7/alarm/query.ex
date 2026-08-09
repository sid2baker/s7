defmodule S7.Alarm.Query do
  @moduledoc """
  Raw-first result of one classic alarm query.

  Query record headers are decoded where the captured format is unambiguous.
  CPU-family-specific record tails remain in `details` and every record retains
  its complete `raw` representation.
  """

  @enforce_keys [
    :selector,
    :function_id,
    :reported_count,
    :return_code,
    :transport_size,
    :complete_length,
    :records,
    :raw
  ]
  defstruct [
    :selector,
    :function_id,
    :reported_count,
    :return_code,
    :transport_size,
    :complete_length,
    :records,
    :raw
  ]

  @type selector :: {:alarm_type, :alarm_s | :alarm_8} | {:event_id, non_neg_integer()}
  @type t :: %__MODULE__{
          selector: selector(),
          function_id: byte(),
          reported_count: byte(),
          return_code: byte(),
          transport_size: byte(),
          complete_length: non_neg_integer(),
          records: [__MODULE__.Record.t()],
          raw: binary()
        }

  defmodule Record do
    @moduledoc "One bounded alarm-query dataset."

    @enforce_keys [
      :dataset_length,
      :reserved,
      :alarm_type,
      :event_id,
      :reserved_state,
      :event_state,
      :ack_state_going,
      :ack_state_coming,
      :details,
      :raw
    ]
    defstruct [
      :dataset_length,
      :reserved,
      :alarm_type,
      :event_id,
      :reserved_state,
      :event_state,
      :ack_state_going,
      :ack_state_coming,
      :details,
      :raw
    ]

    @type t :: %__MODULE__{
            dataset_length: byte(),
            reserved: non_neg_integer(),
            alarm_type: :scan | :alarm_8 | :alarm_s | byte(),
            event_id: non_neg_integer(),
            reserved_state: byte(),
            event_state: byte(),
            ack_state_going: byte(),
            ack_state_coming: byte(),
            details: binary(),
            raw: binary()
          }
  end
end
