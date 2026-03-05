defmodule OpencodeEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :opencode_ex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:opencode_client, path: "../../apps/opencode_client"},
      {:agent_wire, path: "../../apps/agent_wire"}
    ]
  end
end
