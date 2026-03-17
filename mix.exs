defmodule CIA.MixProject do
  use Mix.Project

  def project do
    [
      app: :cia,
      version: "0.1.0",
      description: description(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/seanmor5/cia",
      homepage_url: "https://github.com/seanmor5/cia",
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:websockex, "~> 0.4.3"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "CIA",
      extras: ["README.md"] ++ guide_extras(),
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: guide_extras()
      ],
      source_ref: "main",
      source_url: "https://github.com/seanmor5/cia"
    ]
  end

  defp guide_extras do
    Path.wildcard("guides/**/*.livemd")
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Manage background agents directly in your Elixir app."
  end
end
