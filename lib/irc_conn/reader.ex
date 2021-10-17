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

defmodule Matrix2051.IrcConn.Reader do
  @moduledoc """
    Reads from a client, and sends commands to the handler.
  """

  use Task, restart: :permanent

  require Logger

  def start_link(args) do
    Task.start_link(__MODULE__, :serve, [args])
  end

  def serve(args) do
    {supervisor, sock} = args
    loop_serve(supervisor, sock)
  end

  defp loop_serve(supervisor, sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        {:ok, command} = Matrix2051.Irc.Command.parse(line)
        Registry.send({Matrix2051.Registry, {supervisor, :irc_handler}}, command)
        loop_serve(supervisor, sock)

      {:error, :closed} ->
        Supervisor.stop(supervisor)
    end
  end
end
