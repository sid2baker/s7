defmodule S7.Protocol.DecoderSafetyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias S7.CyclicSubscription

  alias S7.Protocol.{
    Cyclic,
    DataItem,
    Header,
    Item,
    PDU,
    Programmer,
    SetupCommunication,
    UserData
  }

  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Transport.{COTP, TPKT}

  property "public wire decoders return tagged results for arbitrary binaries" do
    check all(binary <- binary(max_length: 512), max_runs: 500) do
      assert tagged?(TPKT.decode(binary))
      assert tagged?(COTP.decode(binary))
      assert tagged?(Header.decode(binary))
      assert tagged?(PDU.decode(binary))
      assert tagged?(Item.decode(binary))
      assert tagged?(DataItem.decode(binary))
      assert tagged?(SetupCommunication.decode(binary))
      assert tagged?(Programmer.decode_service_data(binary, :programmer_diagnostic))
    end
  end

  property "cyclic decoders return tagged results for arbitrary service payloads" do
    check all(
            binary <- binary(max_length: 512),
            subfunction <- member_of([0x01, 0x04, 0x05, 0x07]),
            sequence <- integer(0..0xFF),
            max_runs: 500
          ) do
      request = %UserData{
        parameter: %Parameter{
          method: 0x11,
          type: :request,
          function_group: :cyclic,
          subfunction: subfunction,
          sequence: sequence
        },
        payload: %Payload{return_code: 0xFF, transport_size: 0x09, data: binary}
      }

      assert tagged?(Cyclic.decode_request(request, :decoder_safety))

      indication = %UserData{
        parameter: %Parameter{
          method: 0x12,
          type: :indication,
          function_group: :cyclic,
          subfunction: 0x05,
          sequence: 1,
          data_unit_reference: 0,
          last_data_unit: 0,
          error_code: 0
        },
        payload: %Payload{return_code: 0xFF, transport_size: 0x09, data: binary}
      }

      subscription = %CyclicSubscription{
        connection: self(),
        reference: make_ref(),
        job_id: 1,
        mode: :change_driven,
        interval: nil,
        item_specs: [],
        typed?: false
      }

      assert tagged?(Cyclic.decode_indication(indication, subscription, :decoder_safety))
    end
  end

  defp tagged?({tag, _value}) when tag in [:more, :error], do: true
  defp tagged?({:ok, _value}), do: true
  defp tagged?({:ok, _value, _remaining}), do: true
  defp tagged?(_result), do: false
end
