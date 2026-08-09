defmodule S7.Test.DeviceQualification do
  @moduledoc false

  alias S7.Address

  @families ~w(plcsim_advanced s7_300 s7_400 s7_1200 s7_1500)
  @supported_capabilities MapSet.new(
                            ~w(areas szl cp_info blocks upload clock clock_write security programmer cyclic alarms alarm_event)
                          )
  @required_read_areas MapSet.new([:inputs, :outputs, :markers, :peripheral])
  @connection_types %{
    "programming_device" => :programming_device,
    "operator_panel" => :operator_panel,
    "basic" => :basic
  }
  @block_types %{
    "ob" => :ob,
    "db" => :db,
    "sdb" => :sdb,
    "fc" => :fc,
    "sfc" => :sfc,
    "fb" => :fb,
    "sfb" => :sfb
  }

  def capabilities do
    capabilities =
      "S7_QUAL_CAPABILITIES"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> MapSet.new()

    unknown = MapSet.difference(capabilities, @supported_capabilities)

    if MapSet.size(unknown) > 0 do
      raise "unsupported S7_QUAL_CAPABILITIES: #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end

    capabilities
  end

  def config! do
    family = required!("S7_QUAL_FAMILY")
    capabilities = capabilities()

    if family not in @families do
      raise "S7_QUAL_FAMILY must be one of #{Enum.join(@families, ", ")}"
    end

    %{
      host: required!("S7_QUAL_HOST"),
      port: integer("S7_QUAL_PORT", 102),
      rack: integer("S7_QUAL_RACK", 0),
      slot: integer("S7_QUAL_SLOT", 2),
      connection_type: connection_type!(),
      timeout: integer("S7_QUAL_TIMEOUT", 5_000),
      family: family,
      order_number: required!("S7_QUAL_ORDER_NUMBER"),
      firmware: required!("S7_QUAL_FIRMWARE"),
      access: required!("S7_QUAL_ACCESS"),
      db_number: integer("S7_QUAL_DB", 1),
      db_offset: integer("S7_QUAL_DB_OFFSET", 0),
      scratch_size: integer("S7_QUAL_SCRATCH_SIZE", 64),
      block_type: block_type!(),
      block_number: integer("S7_QUAL_BLOCK_NUMBER", 1),
      cyclic_interval: integer("S7_QUAL_CYCLIC_INTERVAL", 1_000),
      alarm_type: alarm_type!(),
      confirm_writes: required!("S7_QUAL_CONFIRM_WRITES"),
      report_dir: required!("S7_QUAL_REPORT_DIR")
    }
    |> validate_config!(capabilities)
  end

  def connect(config) do
    S7.connect(config.host,
      port: config.port,
      rack: config.rack,
      slot: config.slot,
      connection_type: config.connection_type,
      timeout: config.timeout,
      max_jobs: 4
    )
  end

  def scratch(config, data_type, relative_offset, opts \\ []) do
    %Address{
      area: :db,
      db_number: config.db_number,
      byte_offset: config.db_offset + relative_offset,
      bit_offset: Keyword.get(opts, :bit_offset),
      data_type: data_type,
      count: Keyword.get(opts, :count, 1)
    }
  end

  def write_session_metadata!(config, info) do
    File.mkdir_p!(config.report_dir)

    metadata = [
      "family=#{config.family}",
      "configured_order_number=#{config.order_number}",
      "firmware=#{config.firmware}",
      "access=#{config.access}",
      "host=#{config.host}",
      "port=#{config.port}",
      "rack=#{config.rack}",
      "slot=#{config.slot}",
      "connection_type=#{config.connection_type}",
      "negotiated_pdu=#{info.pdu_size}",
      "negotiated_jobs=#{info.max_jobs}",
      "negotiated_tpdu=#{info.tpdu_size}"
    ]

    File.write!(
      Path.join(config.report_dir, "session-metadata.txt"),
      Enum.join(metadata, "\n") <> "\n"
    )
  end

  def write_observed_identity!(config, order_number, firmware) do
    File.write!(
      Path.join(config.report_dir, "observed-identity.txt"),
      "observed_order_number=#{order_number}\nobserved_firmware=#{firmware}\n"
    )
  end

  def restore_scratch!(client, config, original) do
    address = scratch(config, :byte, 0, count: config.scratch_size)

    case S7.write_raw(client, address, original) do
      :ok ->
        :ok

      {:error, _error} ->
        restore_scratch_with_new_session!(config, address, original)
    end
  end

  def read_addresses! do
    addresses =
      case System.get_env("S7_QUAL_READ_ADDRESSES") do
        nil -> raise "S7_QUAL_READ_ADDRESSES is required for the areas capability"
        values -> values |> String.split(",", trim: true) |> Enum.map(&parse_address!/1)
      end

    present = addresses |> Enum.map(& &1.area) |> MapSet.new()
    missing = MapSet.difference(@required_read_areas, present)

    if MapSet.size(missing) > 0 do
      raise "S7_QUAL_READ_ADDRESSES is missing areas: #{missing |> Enum.sort() |> Enum.join(", ")}"
    end

    addresses
  end

  def password!, do: required!("S7_QUAL_PASSWORD")

  defp validate_config!(config, capabilities) do
    config
    |> validate_confirmation!()
    |> validate_endpoint!()
    |> validate_scratch!()
    |> validate_identity!()
    |> validate_alarm_capabilities!(capabilities)
  end

  defp validate_confirmation!(config) do
    if config.confirm_writes == "qualified_scratch_db" do
      config
    else
      raise "S7_QUAL_CONFIRM_WRITES must equal qualified_scratch_db"
    end
  end

  defp validate_endpoint!(config) do
    cond do
      config.port not in 1..65_535 ->
        raise "S7_QUAL_PORT must be in 1..65535"

      config.rack not in 0..7 ->
        raise "S7_QUAL_RACK must be in 0..7"

      config.slot not in 0..31 ->
        raise "S7_QUAL_SLOT must be in 0..31"

      config.timeout <= 0 ->
        raise "S7_QUAL_TIMEOUT must be positive"

      config.db_number not in 1..65_535 ->
        raise "S7_QUAL_DB must be in 1..65535"

      true ->
        config
    end
  end

  defp validate_scratch!(config) do
    cond do
      config.db_offset < 0 ->
        raise "S7_QUAL_DB_OFFSET must be non-negative"

      config.scratch_size not in 64..65_535 ->
        raise "S7_QUAL_SCRATCH_SIZE must be in 64..65535"

      config.db_offset + config.scratch_size > 0x200000 ->
        raise "the qualification scratch range exceeds the S7ANY address space"

      true ->
        config
    end
  end

  defp validate_identity!(config) do
    if Regex.match?(~r/\A\d+\.\d+\.\d+\z/, config.firmware) do
      config
    else
      raise "S7_QUAL_FIRMWARE must use major.minor.patch"
    end
  end

  defp validate_alarm_capabilities!(config, capabilities) do
    alarm_capabilities = MapSet.new(["alarms", "alarm_event"])

    if config.alarm_type == nil and not MapSet.disjoint?(capabilities, alarm_capabilities) do
      raise "S7_QUAL_ALARM_TYPE is required for alarm capabilities"
    else
      config
    end
  end

  defp restore_scratch_with_new_session!(config, address, original) do
    case connect(config) do
      {:ok, recovery} ->
        try do
          case S7.write_raw(recovery, address, original) do
            :ok -> :ok
            result -> raise "failed to restore qualification scratch DB: #{inspect(result)}"
          end
        after
          S7.close(recovery)
        end

      result ->
        raise "failed to reconnect while restoring qualification scratch DB: #{inspect(result)}"
    end
  end

  defp parse_address!(value) do
    value = String.trim(value)

    case Address.parse(value) do
      {:ok, address} ->
        address

      {:error, error} ->
        raise "invalid qualification read address #{inspect(value)}: #{inspect(error)}"
    end
  end

  defp connection_type! do
    value = System.get_env("S7_QUAL_CONNECTION_TYPE", "programming_device")

    Map.get(@connection_types, value) ||
      raise "S7_QUAL_CONNECTION_TYPE must be programming_device, operator_panel, or basic"
  end

  defp block_type! do
    value = System.get_env("S7_QUAL_BLOCK_TYPE", "db")
    Map.get(@block_types, value) || raise "unsupported S7_QUAL_BLOCK_TYPE #{inspect(value)}"
  end

  defp alarm_type! do
    case System.get_env("S7_QUAL_ALARM_TYPE") do
      "alarm_s" -> :alarm_s
      "alarm_8" -> :alarm_8
      nil -> nil
      value -> raise "unsupported S7_QUAL_ALARM_TYPE #{inspect(value)}"
    end
  end

  defp integer(name, default) do
    value = System.get_env(name, Integer.to_string(default))

    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> raise "#{name} must be an integer"
    end
  end

  defp required!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _other -> raise "#{name} is required"
    end
  end
end

defmodule S7.ClassicDeviceQualificationTest do
  use ExUnit.Case, async: false

  alias S7.{
    Alarm,
    Block,
    Cyclic,
    PLC,
    Programmer,
    Result,
    SZL
  }

  alias S7.Test.DeviceQualification, as: Qualification

  @moduletag :qualification
  @capabilities Qualification.capabilities()

  setup_all do
    {:ok, config: Qualification.config!()}
  end

  setup %{config: config} do
    assert {:ok, client} = Qualification.connect(config)
    info = S7.TestSupport.info!(client)
    Qualification.write_session_metadata!(config, info)
    on_exit(fn -> S7.close(client) end)
    {:ok, client: client, info: info}
  end

  test "negotiates a bounded classic session", %{client: client, info: info} do
    assert %{state: :ready, pdu_size: pdu_size, max_jobs: max_jobs, tpdu_size: tpdu_size} = info
    assert pdu_size > 0
    assert max_jobs > 0
    assert tpdu_size > 0
    assert S7.close(client) == :ok
  end

  test "round-trips typed, raw, multi-item, and split DB access", %{
    client: client,
    config: config
  } do
    scratch = Qualification.scratch(config, :byte, 0, count: config.scratch_size)
    assert {:ok, original} = S7.read_raw(client, scratch)
    on_exit(fn -> Qualification.restore_scratch!(client, config, original) end)

    pattern = for index <- 0..(config.scratch_size - 1), into: <<>>, do: <<rem(index, 256)>>
    assert S7.write_raw(client, scratch, pattern) == :ok
    assert S7.read_raw(client, scratch) == {:ok, pattern}

    typed = [
      {Qualification.scratch(config, :bit, 0, bit_offset: 0), true},
      {Qualification.scratch(config, :byte, 1), 0xA5},
      {Qualification.scratch(config, :word, 2), 0xBEEF},
      {Qualification.scratch(config, :dword, 4), 0x1234_5678},
      {Qualification.scratch(config, :int, 8), -12_345},
      {Qualification.scratch(config, :dint, 10), -123_456_789},
      {Qualification.scratch(config, :real, 14), 12.5}
    ]

    assert {:ok, write_results} = S7.write_many(client, typed)
    assert Enum.all?(write_results, &match?(%Result{status: :ok}, &1))

    assert {:ok, read_results} = S7.read_many(client, Enum.map(typed, &elem(&1, 0)))
    assert Enum.map(read_results, & &1.value) == Enum.map(typed, &elem(&1, 1))

    split_items =
      for relative_offset <- 0..29 do
        {Qualification.scratch(config, :byte, 32 + relative_offset), relative_offset + 1}
      end

    assert {:ok, split_writes} = S7.write_many(client, split_items)
    assert Enum.all?(split_writes, &match?(%Result{status: :ok}, &1))

    assert {:ok, split_reads} =
             S7.read_many(client, Enum.map(split_items, &elem(&1, 0)))

    assert Enum.map(split_reads, & &1.value) == Enum.map(split_items, &elem(&1, 1))
  end

  test "verifies the configured CPU identity", %{client: client, config: config} do
    assert {:ok, %PLC.OrderCode{code: order_number, version: version}} = S7.order_code(client)
    observed_firmware = version |> Tuple.to_list() |> Enum.join(".")

    Qualification.write_observed_identity!(config, order_number, observed_firmware)
    assert order_number == config.order_number
    assert observed_firmware == config.firmware
  end

  @tag skip: if("areas" in @capabilities, do: false, else: "areas capability not declared")
  test "reads configured input, output, marker, and peripheral addresses", %{client: client} do
    for address <- Qualification.read_addresses!() do
      assert {:ok, value} = S7.read_raw(client, address)
      assert is_binary(value)
    end
  end

  @tag skip: if("szl" in @capabilities, do: false, else: "szl capability not declared")
  test "reads raw and typed CPU metadata", %{client: client} do
    assert {:ok, %SZL{records: [_ | _]}} = S7.read_szl(client, 0x0011)
    assert {:ok, %PLC.CPUInfo{}} = S7.cpu_info(client)
    assert {:ok, %PLC.Status{state: state}} = S7.plc_status(client)
    assert state in [:run, :stop, :unknown]
  end

  @tag skip: if("cp_info" in @capabilities, do: false, else: "cp_info capability not declared")
  test "reads communication processor limits", %{client: client} do
    assert {:ok, %PLC.CPInfo{max_pdu_length: maximum}} = S7.cp_info(client)
    assert maximum > 0
  end

  @tag skip: if("blocks" in @capabilities, do: false, else: "blocks capability not declared")
  test "reads block inventory and configured block metadata", %{client: client, config: config} do
    assert {:ok, %Block.Inventory{}} = S7.block_counts(client)
    assert {:ok, entries} = S7.list_blocks(client, config.block_type)
    expected = %Block{type: config.block_type, number: config.block_number}
    assert Enum.any?(entries, &(&1.block == expected))
    assert {:ok, %Block.Info{block: ^expected}} = S7.block_info(client, expected)
  end

  @tag skip: if("upload" in @capabilities, do: false, else: "upload capability not declared")
  test "uploads and parses the configured block", %{client: client, config: config} do
    block = %Block{type: config.block_type, number: config.block_number}
    assert {:ok, %Block.Image{block: ^block}} = S7.upload_block(client, block)
  end

  @tag skip: if("clock" in @capabilities, do: false, else: "clock capability not declared")
  test "reads the PLC clock", %{client: client} do
    assert {:ok, %PLC.Clock{datetime: %NaiveDateTime{}}} = S7.read_clock(client)
  end

  @tag skip:
         if("clock_write" in @capabilities,
           do: false,
           else: "clock_write capability not declared"
         )
  test "writes and restores the PLC clock", %{client: client} do
    assert {:ok, %PLC.Clock{datetime: original}} = S7.read_clock(client)
    on_exit(fn -> S7.set_clock(client, original) end)
    assert S7.set_clock(client, original) == :ok
    assert {:ok, %PLC.Clock{datetime: observed}} = S7.read_clock(client)
    assert NaiveDateTime.diff(observed, original, :second) in -1..1
  end

  @tag skip: if("security" in @capabilities, do: false, else: "security capability not declared")
  test "changes and clears classic session authorization", %{client: client} do
    assert S7.authenticate(client, Qualification.password!()) == :ok
    on_exit(fn -> S7.logout(client) end)
    assert %{authenticated: true} = S7.TestSupport.info!(client)
    assert S7.logout(client) == :ok
    assert %{authenticated: false} = S7.TestSupport.info!(client)
  end

  @tag skip:
         if("programmer" in @capabilities, do: false, else: "programmer capability not declared")
  test "samples one programmer variable-status item", %{client: client, config: config} do
    address = Qualification.scratch(config, :word, 2)

    assert {:ok, %Programmer.VariableStatus{items: [%Programmer.VariableStatus.Item{error: nil}]}} =
             S7.variable_status(client, [address], timeout: 10_000, step_timeout: 5_000)
  end

  @tag skip: if("cyclic" in @capabilities, do: false, else: "cyclic capability not declared")
  test "receives and tears down a cyclic update", %{client: client, config: config} do
    address = Qualification.scratch(config, :word, 2)

    assert {:ok, subscription} =
             S7.subscribe_cyclic(client, [address],
               interval: config.cyclic_interval,
               timeout: 10_000,
               step_timeout: 5_000
             )

    try do
      assert {:ok, %Cyclic.Event{items: [%Cyclic.Event.Item{error: nil}]}} =
               S7.next_cyclic(client, subscription, 10_000)
    after
      assert S7.unsubscribe_cyclic(client, subscription) == :ok
    end
  end

  @tag skip: if("alarms" in @capabilities, do: false, else: "alarms capability not declared")
  test "subscribes, queries, and tears down the configured alarm family", %{
    client: client,
    config: config
  } do
    assert config.alarm_type in [:alarm_s, :alarm_8]
    assert {:ok, subscription} = S7.subscribe_alarms(client, config.alarm_type)

    try do
      assert {:ok, %Alarm.Query{}} = S7.query_alarms(client, config.alarm_type)
    after
      assert S7.unsubscribe_alarms(client, subscription) == :ok
    end
  end

  @tag skip:
         if("alarm_event" in @capabilities,
           do: false,
           else: "alarm_event capability not declared"
         )
  test "receives and explicitly acknowledges an alarm event", %{client: client, config: config} do
    assert config.alarm_type in [:alarm_s, :alarm_8]
    assert {:ok, subscription} = S7.subscribe_alarms(client, config.alarm_type)

    try do
      assert {:ok, %Alarm.Event{} = event} = S7.next_alarm(client, subscription, 30_000)
      assert {:ok, results} = S7.acknowledge_alarms(client, event)
      assert Enum.all?(results, &match?(%Alarm.Acknowledgement.Result{status: :ok}, &1))
    after
      assert S7.unsubscribe_alarms(client, subscription) == :ok
    end
  end
end
