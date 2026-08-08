defmodule S7.Protocol.UserData.Parameter do
  @moduledoc """
  The common parameter item used by classic S7 userdata services.

  The optional data-unit fields are present together when the item length is
  eight bytes. Raw method, sequence, data-unit, and error values are retained
  because their precise use varies between service groups.
  """

  @enforce_keys [:method, :type, :function_group, :subfunction, :sequence]
  defstruct [
    :method,
    :type,
    :function_group,
    :subfunction,
    :sequence,
    :data_unit_reference,
    :last_data_unit,
    :error_code
  ]

  @type function_type :: :indication | :request | :response

  @type function_group ::
          :programmer
          | :cyclic
          | :blocks
          | :cpu
          | :security
          | :bsend
          | :time
          | :data_record_routing
          | :nc_programming
          | 0..0x3F

  @type t :: %__MODULE__{
          method: byte(),
          type: function_type(),
          function_group: function_group(),
          subfunction: byte(),
          sequence: byte(),
          data_unit_reference: byte() | nil,
          last_data_unit: byte() | nil,
          error_code: 0..0xFFFF | nil
        }
end
