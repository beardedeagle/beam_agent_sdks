defmodule ClaudeEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/beardedeagle/beam_agent_sdks"

  def project do
    [
      app: :claude_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: "Elixir wrapper for the Claude Code agent SDK (Erlang/OTP)",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ClaudeEx.Application, []}
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:claude_agent_sdk, path: "../../apps/claude_agent_sdk"},
      {:agent_wire, path: "../../apps/agent_wire"},
      {:agent_wire_ex, path: "../agent_wire_ex"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "ClaudeEx",
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
