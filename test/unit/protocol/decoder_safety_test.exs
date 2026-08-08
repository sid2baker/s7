defmodule S7.Protocol.DecoderSafetyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias S7.Protocol.{DataItem, Header, Item, PDU, SetupCommunication}
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
    end
  end

  defp tagged?({tag, _value}) when tag in [:more, :error], do: true
  defp tagged?({:ok, _value}), do: true
  defp tagged?({:ok, _value, _remaining}), do: true
  defp tagged?(_result), do: false
end
