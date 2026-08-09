[
  layers: [
    public: ["S7", "S7.Client"],
    runtime: ["S7.Connection", "S7.Connection.*"],
    observability: "S7.Telemetry",
    protocol: ["S7.Protocol", "S7.Protocol.*"],
    transport: "S7.Transport.*",
    model: [
      "S7.Address",
      "S7.Alarm.Acknowledgement",
      "S7.Alarm.Acknowledgement.*",
      "S7.Alarm.Event",
      "S7.Alarm.Event.*",
      "S7.Alarm.Query",
      "S7.Alarm.Query.*",
      "S7.Alarm.Subscription",
      "S7.Alarm.Timestamp",
      "S7.Block",
      "S7.Block.Entry",
      "S7.Block.Info",
      "S7.Block.Image",
      "S7.Block.Inventory",
      "S7.Data",
      "S7.Destructive",
      "S7.Error",
      "S7.Options",
      "S7.PLC.Clock",
      "S7.Result",
      "S7.SessionPassword",
      "S7.TSAP"
    ]
  ],
  deps: [
    forbidden: [
      {:public, :protocol},
      {:public, :transport},
      {:model, :public},
      {:model, :runtime},
      {:model, :protocol},
      {:model, :transport},
      {:model, :observability},
      {:observability, :model},
      {:observability, :protocol},
      {:observability, :public},
      {:observability, :runtime},
      {:observability, :transport},
      {:protocol, :public},
      {:protocol, :runtime},
      {:protocol, :observability},
      {:transport, :public},
      {:transport, :runtime},
      {:transport, :protocol},
      {:transport, :model},
      {:transport, :observability}
    ]
  ],
  calls: [
    forbidden: [
      {"S7.Protocol*", [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]},
      {"S7.Transport.*", [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]},
      {["S7.Address", "S7.Alarm*", "S7.Block*", "S7.Data", "S7.Destructive", "S7.Error", "S7.Options",
        "S7.PLC.Clock", "S7.Result", "S7.SessionPassword", "S7.TSAP"],
       [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]}
    ]
  ]
]
