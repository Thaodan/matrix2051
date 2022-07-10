##
# Copyright (C) 2021  Valentin Lorentz
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License version 3,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
###

defmodule M51.MixProject do
  use Mix.Project

  def project do
    [
      app: :matrix2051,
      version: version(),
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        matrix2051: [
          version: version(),
          applications: [matrix2051: :permanent],
          include_erts: false
        ]
      ]
    ]
  end

  defp version do
    "0.1.0"
  end

  def application do
    [
      mod: {M51.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # only using :mochiweb_html
      {:mochiweb, "~> 2.22"},
      {:jason, "~> 1.2"},
      {:httpoison, "~> 1.7"},
      {:mox, "~> 1.0.0", only: :test}
    ]
  end
end
