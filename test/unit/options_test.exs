defmodule S7.OptionsTest do
  use ExUnit.Case, async: true

  alias S7.{Error, Options}

  test "validates keyword option keys and positive bounded values" do
    assert Options.validate_keys([timeout: 10], [:timeout], :test) == :ok
    assert Options.positive([timeout: 10], :timeout, 5, 20, :test) == {:ok, 10}
    assert Options.positive([], :timeout, 5, 20, :test) == {:ok, 5}

    assert {:error, %Error{reason: :invalid_option, details: %{option: :unknown}}} =
             Options.validate_keys([unknown: true], [:timeout], :test)

    assert {:error, %Error{reason: :invalid_options}} =
             Options.validate_keys([:not_a_keyword], [:timeout], :test)

    assert {:error, %Error{reason: :invalid_options}} =
             Options.validate_keys(:not_a_list, [:timeout], :test)

    for value <- [0, 21, :infinity] do
      assert {:error, %Error{reason: :invalid_option, details: %{value: ^value}}} =
               Options.positive([timeout: value], :timeout, 5, 20, :test)
    end
  end
end
