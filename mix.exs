defmodule S7.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sid2baker/s7"

  def project do
    [
      app: :s7,
      version: @version,
      elixir: ">= 1.17.0 and < 2.0.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: "S7",
      description: "An OTP-native classic Siemens S7comm client over RFC 1006",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      test_coverage: [summary: [threshold: 90]],
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, soak: :test, "release.check": :dev]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.4"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "deps.audit",
        "format --check-formatted",
        "test --cover",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ],
      "release.check": "cmd bash scripts/check_release.sh",
      soak: "test --only soak test/soak"
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "docs",
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "mix.exs",
        "README.md",
        "SECURITY.md"
      ],
      licenses: ["MIT"],
      links: %{
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md",
        "GitHub" => @source_url,
        "Security" => @source_url <> "/blob/main/SECURITY.md"
      },
      maintainers: ["sid2baker"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "docs/architecture.md",
        "docs/classic-completion.md",
        "docs/compatibility.md",
        "docs/error-and-retry-semantics.md",
        "docs/interoperability.md",
        "docs/protocol-support.md",
        "docs/qualification.md",
        "docs/releasing.md",
        "docs/roadmap.md",
        "docs/telemetry.md"
      ],
      groups_for_extras: [
        Guides:
          ~r{docs/(architecture|classic-completion|error-and-retry-semantics|protocol-support|telemetry)\.md},
        Qualification:
          ~r{docs/(compatibility|interoperability|qualification|releasing|roadmap)\.md},
        Project: ["CHANGELOG.md", "SECURITY.md"]
      ],
      groups_for_modules: [
        "Public API": [
          S7,
          S7.Address,
          S7.Alarm.Acknowledgement,
          S7.Alarm.Acknowledgement.Result,
          S7.Alarm.Event,
          S7.Alarm.Event.Object,
          S7.Alarm.Event.Object.AssociatedValue,
          S7.Alarm.Query,
          S7.Alarm.Query.Record,
          S7.Alarm.Subscription,
          S7.Alarm.Timestamp,
          S7.Block,
          S7.Block.Entry,
          S7.Block.Info,
          S7.Block.Image,
          S7.Block.Inventory,
          S7.Cyclic.Event,
          S7.Cyclic.Event.Item,
          S7.Cyclic.Interval,
          S7.Cyclic.Subscription,
          S7.Data,
          S7.Error,
          S7.PLC.CPInfo,
          S7.PLC.CPUInfo,
          S7.PLC.Clock,
          S7.PLC.OrderCode,
          S7.PLC.Status,
          S7.Programmer.Event,
          S7.Programmer.VariableStatus,
          S7.Programmer.VariableStatus.Item,
          S7.Result,
          S7.SZL,
          S7.Telemetry
        ],
        "S7 Protocol": [
          S7.Protocol.Alarm,
          S7.Protocol.BlockDownload,
          S7.Protocol.BlockUpload,
          S7.Protocol.Blocks,
          S7.Protocol.Clock,
          S7.Protocol.Cyclic,
          S7.Protocol.DataItem,
          S7.Protocol.Header,
          S7.Protocol.Item,
          S7.Protocol.PDU,
          S7.Protocol.PDUPlanner,
          S7.Protocol.PIService,
          S7.Protocol.PLCControl,
          S7.Protocol.Programmer,
          S7.Protocol.Programmer.Job,
          S7.Protocol.ReadVar,
          S7.Protocol.Security,
          S7.Protocol.SetupCommunication,
          S7.Protocol.SZL,
          S7.Protocol.UserData,
          S7.Protocol.WriteVar
        ],
        Transport: [
          S7.Transport.COTP,
          S7.Transport.COTP.ConnectionConfirm,
          S7.Transport.COTP.ConnectionRequest,
          S7.Transport.COTP.Data,
          S7.Transport.COTP.DisconnectConfirm,
          S7.Transport.COTP.DisconnectRequest,
          S7.Transport.COTP.ErrorTPDU,
          S7.Transport.TPKT,
          S7.TSAP
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
