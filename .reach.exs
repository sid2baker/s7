[
  layers: [
    public: ["S7", "S7.Client"],
    runtime: ["S7.Connection", "S7.Connection.*"],
    protocol: ["S7.Protocol", "S7.Protocol.*"],
    transport: "S7.Transport.*",
    model: ["S7.Address", "S7.Data", "S7.Error", "S7.TSAP"]
  ],
  deps: [
    forbidden: [
      {:public, :protocol},
      {:public, :transport},
      {:model, :public},
      {:model, :runtime},
      {:model, :protocol},
      {:model, :transport},
      {:protocol, :public},
      {:protocol, :runtime},
      {:transport, :public},
      {:transport, :runtime},
      {:transport, :protocol},
      {:transport, :model}
    ]
  ],
  calls: [
    forbidden: [
      {"S7.Protocol*", [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]},
      {"S7.Transport.*", [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]},
      {["S7.Address", "S7.Data", "S7.Error", "S7.TSAP"],
       [":gen_tcp.*", ":gen_statem.*", "GenServer.*"]}
    ]
  ]
]
