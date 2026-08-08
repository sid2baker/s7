defmodule S7.ConnectionTest do
  use ExUnit.Case, async: true

  alias S7.Connection

  test "PDU references wrap without producing zero" do
    assert Connection.next_reference(0) == 1
    assert Connection.next_reference(1) == 2
    assert Connection.next_reference(0xFFFE) == 0xFFFF
    assert Connection.next_reference(0xFFFF) == 1
  end
end
