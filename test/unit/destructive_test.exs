defmodule S7.DestructiveTest do
  use ExUnit.Case, async: true

  alias S7.{Destructive, Error}

  test "requires an exact per-call confirmation and validates bounds" do
    assert {:ok, %{timeout: 30_000, step_timeout: 5_000}} =
             Destructive.validate_options([confirm: :delete_block], :delete_block, :delete_block)

    assert {:error,
            %Error{
              reason: :destructive_confirmation_required,
              details: %{expected: :delete_block, received: :download_block}
            }} =
             Destructive.validate_options(
               [confirm: :download_block],
               :delete_block,
               :delete_block
             )

    for opts <- [
          [:invalid],
          [confirm: :delete_block, unknown: true],
          [confirm: :delete_block, timeout: 0]
        ] do
      assert {:error, %Error{reason: reason}} =
               Destructive.validate_options(opts, :delete_block, :delete_block)

      assert reason in [:invalid_options, :invalid_option]
    end

    assert {:ok, %{timeout: 12_000, step_timeout: 750}} =
             Destructive.validate_options(
               [confirm: :delete_block, timeout: 12_000, step_timeout: 750],
               :delete_block,
               :delete_block
             )
  end

  test "requires an enabled connection capability" do
    assert Destructive.authorize(%{destructive_operations: true}, :delete_block) == :ok

    assert {:error,
            %Error{
              reason: :destructive_operations_disabled,
              details: %{required_connection_option: {:allow_destructive, true}}
            }} = Destructive.authorize(%{destructive_operations: false}, :delete_block)

    assert {:error, %Error{reason: :destructive_operations_disabled}} =
             Destructive.authorize(%{}, :delete_block)
  end
end
