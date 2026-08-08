defmodule S7.ErrorTest do
  use ExUnit.Case, async: true

  alias S7.Error

  test "formats errors with and without raw codes" do
    timeout = Error.new(:tcp, :read, :timeout)
    denied = Error.new(:s7, :write, :access_denied, code: 3, details: %{item: 1})

    assert Exception.message(timeout) == "read failed at tcp: timeout"
    assert Exception.message(denied) == "write failed at s7: access_denied (code: 3)"
    assert denied.details == %{item: 1}
  end
end
