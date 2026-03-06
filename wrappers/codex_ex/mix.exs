defmodule CodexEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/beardedeagle/beam_agent_sdks"

  def project do
    [
      app: :codex_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: "Elixir wrapper for the Codex CLI agent SDK (Erlang/OTP)",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:codex_app_server, path: "../../apps/codex_app_server"},
      {:agent_wire, path: "../../apps/agent_wire"},
      {:agent_wire_ex, path: "../agent_wire_ex"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "CodexEx",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      links: %{"GitHub" => @source_url}
    ]
  end
end
