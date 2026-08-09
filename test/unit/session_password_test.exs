defmodule S7.SessionPasswordTest do
  use ExUnit.Case, async: true

  alias S7.{Error, SessionPassword}

  test "validates and pads printable one-to-eight-byte passwords" do
    assert {:ok, password} = SessionPassword.new("A")
    assert SessionPassword.padded(password) == "A       "

    assert {:ok, password} = SessionPassword.new("TESTONLY")
    assert SessionPassword.padded(password) == "TESTONLY"
  end

  test "redacts inspection and never returns invalid input in errors" do
    secret = "PRIVATE"
    assert {:ok, password} = SessionPassword.new(secret)
    refute inspect(password) =~ secret
    assert inspect(password) == "#S7.SessionPassword<redacted>"

    for invalid <- ["", "123456789", <<0>>, "pass\nword", :invalid] do
      assert {:error,
              %Error{
                operation: :authenticate,
                reason: :invalid_session_password,
                details: %{}
              } = error} = SessionPassword.new(invalid)

      if is_binary(invalid) and invalid != "" do
        refute inspect(error) =~ invalid
      end
    end
  end
end
