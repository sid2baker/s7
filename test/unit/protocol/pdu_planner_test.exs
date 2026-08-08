defmodule S7.Protocol.PDUPlannerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias S7.{Address, Error}
  alias S7.Protocol.PDUPlanner

  test "calculates exact aligned Read Var and Write Var sizes" do
    byte = address(:byte, 1)
    word = address(:word, 1)

    assert PDUPlanner.read_pdu_sizes([byte, word]) == {:ok, {36, 26}}
    assert PDUPlanner.write_pdu_sizes([{byte, <<1>>}, {word, <<0, 2>>}]) == {:ok, {48, 16}}
  end

  test "splits in order on request and response boundaries" do
    addresses = [address(:byte, 1), address(:word, 1), address(:real, 2)]

    assert PDUPlanner.plan_read(addresses, 35) ==
             {:ok, Enum.map(addresses, &[&1])}

    encoded = [{address(:byte, 1), <<1>>}, {address(:word, 1), <<0, 2>>}]
    assert PDUPlanner.plan_write(encoded, 47) == {:ok, Enum.map(encoded, &[&1])}

    large = address(:byte, 30)

    assert {:error, %Error{reason: :pdu_too_large, details: %{response_size: 48}}} =
             PDUPlanner.plan_read([large], 47)
  end

  test "uses a conservative peer limit and permits an explicit wire limit" do
    addresses = List.duplicate(address(:byte, 1), 21)
    assert {:ok, [first, second]} = PDUPlanner.plan_read(addresses, 10_000)
    assert Enum.count(first) == 20
    assert Enum.count(second) == 1

    addresses = List.duplicate(address(:byte, 1), 256)

    assert {:ok, [first, second]} =
             PDUPlanner.plan_read(addresses, 10_000, maximum_items: 255)

    assert Enum.count(first) == 255
    assert Enum.count(second) == 1
  end

  test "rejects empty, malformed, and size-invalid plans" do
    assert {:error, %Error{reason: :invalid_items}} = PDUPlanner.plan_read([], 480)
    assert {:error, %Error{reason: :invalid_items}} = PDUPlanner.plan_read([:invalid], 480)
    assert {:error, %Error{reason: :invalid_items}} = PDUPlanner.plan_write([], 480)
    assert {:error, %Error{reason: :invalid_items}} = PDUPlanner.plan_write([:invalid], 480)
    assert {:error, %Error{reason: :invalid_items}} = PDUPlanner.plan_read([address(:byte, 1)], 0)

    assert {:error, %Error{reason: :invalid_items}} =
             PDUPlanner.plan_read([address(:byte, 1)], 480, maximum_items: 256)
  end

  property "planned read batches preserve order and fit both PDU directions" do
    check all(counts <- list_of(integer(1..30), min_length: 1, max_length: 100)) do
      addresses = Enum.map(counts, &address(:byte, &1))
      assert {:ok, batches} = PDUPlanner.plan_read(addresses, 240)
      assert List.flatten(batches) == addresses

      for batch <- batches do
        assert {:ok, {request_size, response_size}} = PDUPlanner.read_pdu_sizes(batch)
        assert request_size <= 240
        assert response_size <= 240
      end
    end
  end

  defp address(data_type, count) do
    %Address{area: :db, db_number: 1, byte_offset: 0, data_type: data_type, count: count}
  end
end
