defmodule S7.TSAPTest do
  use ExUnit.Case, async: true

  alias S7.{Error, TSAP}

  test "constructs destination TSAPs explicitly" do
    assert TSAP.for_rack_slot(rack: 0, slot: 2, connection_type: :programming_device) ==
             <<0x01, 0x02>>

    assert TSAP.for_rack_slot(rack: 3, slot: 7, connection_type: :operator_panel) ==
             <<0x02, 0x67>>

    assert TSAP.for_rack_slot(rack: 7, slot: 31, connection_type: :basic) == <<0x03, 0xFF>>
  end

  test "safe construction reports invalid rack, slot, and connection type" do
    assert {:error, %Error{reason: :invalid_rack}} = TSAP.build(rack: 8)
    assert {:error, %Error{reason: :invalid_slot}} = TSAP.build(slot: 32)

    assert {:error, %Error{reason: :invalid_connection_type}} =
             TSAP.build(connection_type: :unknown)
  end
end
