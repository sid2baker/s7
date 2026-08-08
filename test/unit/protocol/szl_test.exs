defmodule S7.Protocol.SZLTest do
  use ExUnit.Case, async: true

  alias S7.{Error, SZL}
  alias S7.Protocol.SZL, as: SZLProtocol
  alias S7.Protocol.UserData
  alias S7.Protocol.UserData.{Parameter, Payload}

  test "assembles first and continuation responses into validated records" do
    limits = %{max_bytes: 64, max_fragments: 4}
    assert {:ok, initial, transaction} = SZLProtocol.start(0x0011, 0, limits)
    assert initial.payload.data == <<0x00, 0x11, 0, 0>>

    raw = <<2::16, 2::16, 0x1111::16, 0x2222::16>>
    <<first::binary-size(3), second::binary>> = raw

    assert {:continue, continuation, transaction} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, first::binary>>, more?: true, sequence: 7),
               transaction,
               :read_szl
             )

    assert %Parameter{
             method: 0x12,
             type: :request,
             sequence: 7,
             data_unit_reference: 0,
             last_data_unit: 0,
             error_code: 0
           } = continuation.parameter

    assert %Payload{return_code: 0x0A, transport_size: 0, data: <<>>} = continuation.payload

    assert {:ok,
            %SZL{
              id: 0x0011,
              index: 0,
              record_length: 2,
              record_count: 2,
              records: [<<0x1111::16>>, <<0x2222::16>>],
              raw: ^raw
            }} = SZLProtocol.consume(response(second), transaction, :read_szl)
  end

  test "rejects fragment identity, extension, transport, and resource violations" do
    assert {:ok, _request, transaction} =
             SZLProtocol.start(0x0011, 0, %{max_bytes: 8, max_fragments: 2})

    assert {:error, %Error{reason: :malformed_response}} =
             SZLProtocol.consume(
               response(<<0x0012::16, 0::16, 0, 0, 0, 0>>),
               transaction,
               :read_szl
             )

    assert {:error, %Error{reason: :malformed_response}} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, 0, 0, 0, 0>>, extension?: false),
               transaction,
               :read_szl
             )

    assert {:error, %Error{reason: :malformed_response}} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, 0, 0, 0, 0>>, transport_size: 4),
               transaction,
               :read_szl
             )

    assert {:error, %Error{reason: :too_many_userdata_fragments}} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, 0, 0>>, more?: true),
               %{transaction | max_fragments: 1},
               :read_szl
             )

    assert {:error, %Error{reason: :userdata_too_large}} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, 0, 0, 0, 0, 1, 2, 3, 4, 5>>),
               transaction,
               :read_szl
             )
  end

  test "rejects a changed data-unit reference across fragments" do
    assert {:ok, _request, transaction} =
             SZLProtocol.start(0x0011, 0, %{max_bytes: 64, max_fragments: 4})

    assert {:continue, _continuation, transaction} =
             SZLProtocol.consume(
               response(<<0x0011::16, 0::16, 0, 2>>, more?: true, data_unit_reference: 7),
               transaction,
               :read_szl
             )

    assert {:error, %Error{reason: :malformed_response}} =
             SZLProtocol.consume(
               response(<<0, 1>>, data_unit_reference: 8),
               transaction,
               :read_szl
             )
  end

  defp response(data, opts \\ []) do
    extension? = Keyword.get(opts, :extension?, true)

    parameter = %Parameter{
      method: 0x12,
      type: :response,
      function_group: :cpu,
      subfunction: 1,
      sequence: Keyword.get(opts, :sequence, 0),
      data_unit_reference: if(extension?, do: Keyword.get(opts, :data_unit_reference, 7)),
      last_data_unit: if(extension?, do: if(Keyword.get(opts, :more?, false), do: 1, else: 0)),
      error_code: if(extension?, do: 0)
    }

    %UserData{
      parameter: parameter,
      payload: %Payload{transport_size: Keyword.get(opts, :transport_size, 9), data: data}
    }
  end
end
