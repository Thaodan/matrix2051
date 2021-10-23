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

defmodule Matrix2051.MatrixClient.Poller do
  @moduledoc """
    Queries the homeserver for new events; including the initial sync.
  """
  use Task, restart: :permanent

  def start_link(args) do
    Task.start_link(__MODULE__, :poll, [args])
  end

  def poll(args) do
    {sup_pid} = args
    Registry.register(Matrix2051.Registry, {sup_pid, :matrix_poller}, nil)

    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    # If we are being restarted, pick up from where the last process stopped.
    since = Matrix2051.MatrixClient.State.poll_since_marker(state)
    handled_event_ids = Matrix2051.MatrixClient.State.handled_events(state)

    if Matrix2051.IrcConn.State.registered(irc_state) do
      loop_poll(sup_pid, since, handled_event_ids)
    else
      receive do
        :start_polling -> loop_poll(sup_pid, since, handled_event_ids)
      end
    end
  end

  def loop_poll(sup_pid, since, handled_event_ids \\ MapSet.new()) do
    client = Matrix2051.IrcConn.Supervisor.matrix_client(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    case Matrix2051.MatrixClient.Client.raw_client(client) do
      nil ->
        # Wait for it to be initialized
        receive do
          :connected -> loop_poll(sup_pid, nil)
        end

      raw_client ->
        since = poll_one(sup_pid, since, handled_event_ids, raw_client)
        Matrix2051.MatrixClient.State.update_poll_since_marker(state, since)
        # do not pass handled_event_ids, no longer needed
        loop_poll(sup_pid, since)
    end
  end

  defp poll_one(sup_pid, since, handled_event_ids, raw_client) do
    query = %{
      # Completely arbitrary value. Just make sure it's lower than recv_timeout below
      "timeout" => "600000"
    }

    query =
      case since do
        nil -> query
        _ -> Map.put(query, "since", since)
      end

    path = "/_matrix/client/r0/sync?" <> URI.encode_query(query)

    # Need to be larger than the timeout above (both in milliseconds)
    options = [recv_timeout: 1_000_000]

    case Matrix2051.Matrix.RawClient.get(raw_client, path, [], options) do
      {:ok, events} ->
        handle_events(sup_pid, events, handled_event_ids)
        events["next_batch"]
    end
  end

  @doc """
    Internal method that dispatches event; public only so it can be unit-tested.
  """
  def handle_events(sup_pid, events, handled_event_ids \\ MapSet.new()) do
    write = nil

    events
    |> Map.get("rooms", %{})
    |> Map.get("join", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} ->
      handle_joined_room(sup_pid, handled_event_ids, room_id, write, event)
    end)

    events
    |> Map.get("rooms", %{})
    |> Map.get("leave", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} ->
      handle_left_room(sup_pid, handled_event_ids, room_id, write, event)
    end)

    events
    |> Map.get("rooms", %{})
    |> Map.get("invite", %{})
    |> Map.to_list()
    |> Enum.map(fn {room_id, event} ->
      handle_invited_room(sup_pid, handled_event_ids, room_id, write, event)
    end)
  end

  defp handle_joined_room(sup_pid, handled_event_ids, room_id, write, room_event) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    new_rooms =
      room_event
      |> Map.get("state", %{})
      |> Map.get("events", [])
      # oldest first
      |> Enum.map(fn event ->
        event_id = Map.get(event, "event_id")

        if !MapSet.member?(handled_event_ids, event_id) do
          sender =
            case Map.get(event, "sender") do
              nil -> nil
              sender -> String.replace_prefix(sender, "@", "")
            end

          handle_event(sup_pid, room_id, sender, true, write, event)
          # Don't mark it handled right now, there is still some processing to
          # do below.
          # Matrix2051.MatrixClient.State.mark_handled_event(state, event_id)
        end
      end)

    # Send self JOIN, RPL_TOPIC/RPL_NOTOPIC, RPL_NAMREPLY
    new_rooms
    |> Enum.filter(fn room -> room != nil end)
    # dedup
    |> Map.new()
    |> Map.to_list()
    |> Enum.map(fn {room_id, {canonical_alias_sender, old_canonical_alias}} ->
      send_channel_welcome(
        sup_pid,
        room_id,
        canonical_alias_sender,
        old_canonical_alias,
        write,
        nil
      )

      Matrix2051.MatrixClient.State.mark_synced(state, room_id)
    end)

    room_event
    |> Map.get("timeline", %{})
    |> Map.get("events", [])
    # oldest first
    |> Enum.map(fn event ->
      event_id = Map.get(event, "event_id")

      if !MapSet.member?(handled_event_ids, event_id) do
        sender =
          case Map.get(event, "sender") do
            nil -> nil
            sender -> String.replace_prefix(sender, "@", "")
          end

        handle_event(sup_pid, room_id, sender, false, write, event)

        Matrix2051.MatrixClient.State.mark_handled_event(state, event_id)
      end
    end)
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        state_event,
        write,
        %{"type" => "m.room.canonical_alias"} = event
      ) do
    new_canonical_alias = event["content"]["alias"]
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)

    old_canonical_alias =
      Matrix2051.MatrixClient.State.set_room_canonical_alias(
        state,
        room_id,
        new_canonical_alias
      )

    if !state_event do
      send_channel_welcome(sup_pid, room_id, sender, old_canonical_alias, write, event)
    end

    {room_id, {sender, old_canonical_alias}}
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        state_event,
        write,
        %{"type" => "m.room.join_rules"} = event
      ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event, write)

    if !state_event do
      mode =
        case event["content"]["join_rule"] do
          "public" -> "-i"
          "knock" -> "+i"
          "invite" -> "+i"
          "private" -> "+i"
        end

      send.(%Matrix2051.Irc.Command{
        tags: %{"account" => sender},
        source: nick2nuh(sender),
        command: "MODE",
        params: [channel, mode]
      })
    end

    nil
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        state_event,
        write,
        %{"type" => "m.room.member"} = event
      ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event, write)

    target = event |> Map.get("state_key", sender) |> String.replace_prefix("@", "")

    case event["content"]["membership"] do
      "join" ->
        was_already_member =
          Matrix2051.MatrixClient.State.room_member_add(
            state,
            room_id,
            target,
            %Matrix2051.Matrix.RoomMember{display_name: Map.get(event["content"], "displayname")}
          )

        if !state_event and !was_already_member do
          send.(%Matrix2051.Irc.Command{
            tags: %{"account" => target},
            source: nick2nuh(target),
            command: "JOIN",
            params: [channel, target, target]
          })
        end

      "leave" ->
        params_tail =
          case Map.get(event["content"], "reason") do
            nil -> []
            reason -> [reason]
          end

        was_already_member = Matrix2051.MatrixClient.State.room_member_del(state, room_id, target)

        if !state_event and was_already_member do
          if sender == target do
            send.(%Matrix2051.Irc.Command{
              tags: %{"account" => target},
              source: nick2nuh(target),
              command: "PART",
              params: [channel | params_tail]
            })
          else
            send.(%Matrix2051.Irc.Command{
              tags: %{"account" => sender},
              source: nick2nuh(sender),
              command: "KICK",
              params: [channel, target | params_tail]
            })
          end
        end

      "ban" ->
        if !state_event do
          send.(%Matrix2051.Irc.Command{
            tags: %{"account" => sender},
            source: nick2nuh(sender),
            command: "MODE",
            params: [channel, "+b", "#{target}!*@*"]
          })
        end

      "invite" ->
        if !state_event do
          send.(%Matrix2051.Irc.Command{
            tags: %{"account" => sender},
            source: nick2nuh(sender),
            command: "INVITE",
            params: [String.replace_prefix(event["state_key"], "@", ""), room_id]
          })
        end

      _ ->
        send.(%Matrix2051.Irc.Command{
          tags: %{"account" => sender},
          command: "NOTICE",
          params: [channel, "Unexpected m.room.member event: " <> Kernel.inspect(event)]
        })
    end

    nil
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        _state_event,
        write,
        %{"type" => "m.room.message"} = event
      ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    member = Matrix2051.MatrixClient.State.room_member(state, room_id, sender)
    send = make_send_function(sup_pid, event, write)

    tags = %{"account" => sender}

    tags =
      case member do
        %Matrix2051.Matrix.RoomMember{display_name: display_name} when display_name != nil ->
          Map.put(tags, "+draft/display-name", display_name)

        _ ->
          tags
      end

    {reply_to, tags} =
      case event["content"] do
        %{"m.relates_to" => %{"m.in_reply_to" => %{"event_id" => reply_to}}} ->
          {reply_to, Map.put(tags, "+draft/reply", reply_to)}

        _ ->
          {nil, tags}
      end

    {command, body} =
      case event["content"] do
        %{
          "msgtype" => "m.text",
          "format" => "org.matrix.custom.html",
          "formatted_body" => formatted_body,
          "body" => body
        } ->
          # TODO: dedup with below
          body =
            if reply_to do
              # Strip the fallback, as described in
              # https://matrix.org/docs/spec/client_server/r0.6.1#stripping-the-fallback
              body
              |> String.split("\n")
              |> Enum.drop_while(fn line -> String.starts_with?(line, "> ") end)
              |> Enum.join("\n")
              |> String.trim_leading("\n")
            else
              body
            end

          {"PRIVMSG", Matrix2051.Format.matrix2irc(formatted_body) || body}

        %{"msgtype" => "m.text", "body" => body} ->
          body =
            if reply_to do
              # Strip the fallback, as described in
              # https://matrix.org/docs/spec/client_server/r0.6.1#stripping-the-fallback
              body
              |> String.split("\n")
              |> Enum.drop_while(fn line -> String.starts_with?(line, "> ") end)
              |> Enum.join("\n")
              |> String.trim_leading("\n")
            else
              body
            end

          {"PRIVMSG", body}

        %{
          "msgtype" => "m.emote",
          "format" => "org.matrix.custom.html",
          "formatted_body" => formatted_body,
          "body" => body
        } ->
          {"PRIVMSG",
           "\x01ACTION " <> (Matrix2051.Format.matrix2irc(formatted_body) || body) <> "\x01"}

        %{"msgtype" => "m.emote", "body" => body} ->
          # TODO: ditto
          {"PRIVMSG", "\x01ACTION " <> body <> "\x01"}

        %{
          "msgtype" => "m.notice",
          "format" => "org.matrix.custom.html",
          "formatted_body" => formatted_body,
          "body" => body
        } ->
          {"NOTICE", Matrix2051.Format.matrix2irc(formatted_body) || body}

        %{"msgtype" => "m.notice", "body" => body} ->
          # TODO: ditto
          {"NOTICE", body}

        %{"msgtype" => "m.image", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.file", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.audio", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"msgtype" => "m.location", "body" => body, "geo_uri" => geo_uri} ->
          {"PRIVMSG", body <> " (" <> geo_uri <> ")"}

        %{"msgtype" => "m.video", "body" => body, "url" => url} ->
          {"PRIVMSG", body <> " " <> format_url(url)}

        %{"body" => body} ->
          # fallback
          {"PRIVMSG", body}

        event when map_size(event) == 0 ->
          # TODO: redaction
          {nil, ""}
      end

    case String.split(body, "\n") do
      [] ->
        nil

      [""] ->
        nil

      [line] ->
        commands =
          Matrix2051.Irc.Command.linewrap(%Matrix2051.Irc.Command{
            tags: tags,
            source: nick2nuh(sender),
            command: command,
            params: [channel, line]
          })

        case commands do
          [command] ->
            send.(command)

          _ ->
            # Drop tags all tags except draft/multiline-concat, they will be on the BATCH opening
            commands =
              Enum.map(commands, fn command ->
                command_tags =
                  command.tags
                  |> Map.to_list()
                  |> Enum.flat_map(fn {k, v} ->
                    case k do
                      "draft/multiline-concat" -> [{k, v}]
                      _ -> []
                    end
                  end)
                  |> Map.new()

                %{command | tags: command_tags}
              end)

            send_multiline_batch(sup_pid, sender, write, event, tags, channel, commands)
        end

      lines ->
        send_multiline_batch(
          sup_pid,
          sender,
          write,
          event,
          tags,
          channel,
          Enum.flat_map(lines, fn line ->
            Matrix2051.Irc.Command.linewrap(%Matrix2051.Irc.Command{
              source: nick2nuh(sender),
              command: command,
              params: [channel, line]
            })
          end)
        )
    end

    nil
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        state_event,
        write,
        %{"type" => "m.room.name"} = event
      ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    send = make_send_function(sup_pid, event, write)

    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    Matrix2051.MatrixClient.State.set_room_name(state, room_id, event["content"]["name"])

    if !state_event do
      topic =
        case compute_topic(sup_pid, room_id) do
          nil -> ""
          {topic, _whotime} -> topic
        end

      send.(%Matrix2051.Irc.Command{
        source: nick2nuh(sender),
        command: "TOPIC",
        params: [channel, topic]
      })
    end

    nil
  end

  def handle_event(
        sup_pid,
        room_id,
        sender,
        state_event,
        write,
        %{"type" => "m.room.topic"} = event
      ) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event, write)

    Matrix2051.MatrixClient.State.set_room_topic(
      state,
      room_id,
      {event["content"]["topic"], sender, event["origin_server_ts"]}
    )

    if !state_event do
      topic =
        case compute_topic(sup_pid, room_id) do
          nil -> ""
          {topic, _whotime} -> topic
        end

      send.(%Matrix2051.Irc.Command{
        source: nick2nuh(sender),
        command: "TOPIC",
        params: [channel, topic]
      })
    end

    nil
  end

  def handle_event(_sup_pid, _room_id, _sender, _state_event, _write, %{"type" => event_type})
      when event_type in [
             "im.vector.modular.widgets",
             "org.matrix.appservice-irc.connection",
             "m.room.avatar",
             "m.room.bot.options",
             "m.room.encryption",
             "m.room.guest_access",
             "m.room.power_levels",
             "m.room.related_groups",
             "m.room.server_acl",
             "m.room.third_party_invite",
             "m.space.child",
             "uk.half-shot.bridge"
           ] do
    # ignore these
  end

  def handle_event(sup_pid, room_id, _sender, _state_event, write, event) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event, write)

    case event["type"] do
      "m.room.create" ->
        nil

      "m.room.history_visibility" ->
        nil

      event_type ->
        send.(%Matrix2051.Irc.Command{
          source: "server",
          command: "NOTICE",
          params: [
            channel,
            "Unknown state event (" <> event_type <> "): " <> Kernel.inspect(event)
          ]
        })
    end

    nil
  end

  defp handle_left_room(sup_pid, _handled_event_ids, _room_id, _write, _event) do
    _state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    _writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
    # TODO
  end

  defp handle_invited_room(sup_pid, handled_event_ids, room_id, write, room_event) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)

    room_event
    |> Map.get("invite_state", %{})
    |> Map.get("events", [])
    # oldest first
    |> Enum.map(fn event ->
      event_id = Map.get(event, "event_id")

      if !MapSet.member?(handled_event_ids, event_id) do
        send = make_send_function(sup_pid, event, write)

        sender =
          case Map.get(event, "sender") do
            nil -> nil
            sender -> String.replace_prefix(sender, "@", "")
          end

        case event do
          %{"type" => "m.room.member", "content" => %{"membership" => "invite"}} ->
            send.(%Matrix2051.Irc.Command{
              tags: %{"account" => sender},
              source: nick2nuh(sender),
              command: "INVITE",
              params: [nick, room_id]
            })

          _ ->
            nil
        end

        Matrix2051.MatrixClient.State.mark_handled_event(state, event_id)
      end
    end)
  end

  defp compute_topic(sup_pid, room_id) do
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    name = Matrix2051.MatrixClient.State.room_name(state, room_id)
    topicwhotime = Matrix2051.MatrixClient.State.room_topic(state, room_id)

    case {name, topicwhotime} do
      {nil, nil} -> nil
      {name, nil} -> {"[" <> name <> "]", nil}
      {nil, {topic, who, time}} -> {"[] " <> topic, {who, time}}
      {name, {topic, who, time}} -> {"[" <> name <> "] " <> topic, {who, time}}
    end
  end

  # Sends self JOIN, RPL_TOPIC/RPL_NOTOPIC, RPL_NAMREPLY
  defp send_channel_welcome(
         sup_pid,
         room_id,
         canonical_alias_sender,
         old_canonical_alias,
         write,
         event
       ) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    capabilities = Matrix2051.IrcConn.State.capabilities(irc_state)
    send = make_send_function(sup_pid, event, write)

    supports_channel_rename = Enum.member?(capabilities, :channel_rename)

    if old_canonical_alias == nil || !supports_channel_rename do
      announce_new_channel(
        Matrix2051.IrcConn.Supervisor,
        sup_pid,
        room_id,
        write,
        event
      )
    end

    if old_canonical_alias != nil do
      if supports_channel_rename do
        new_canonical_alias = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)

        source =
          case canonical_alias_sender do
            nil -> "server"
            _ -> nick2nuh(canonical_alias_sender)
          end

        send.(%Matrix2051.Irc.Command{
          source: source,
          command: "RENAME",
          params: [old_canonical_alias, new_canonical_alias, "Canonical alias changed"]
        })
      else
        close_renamed_channel(
          sup_pid,
          room_id,
          write,
          canonical_alias_sender,
          old_canonical_alias
        )
      end
    end
  end

  defp announce_new_channel(
         Matrix2051.IrcConn.Supervisor,
         sup_pid,
         room_id,
         write,
         event
       ) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)
    channel = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, event, write)

    make_numeric = fn numeric, params ->
      %Matrix2051.Irc.Command{source: "server", command: numeric, params: [nick | params]}
    end

    send_numeric = fn numeric, params ->
      send.(make_numeric.(numeric, params))
    end

    # Join the new channel
    Matrix2051.MatrixClient.State.room_member_add(
      state,
      room_id,
      nick,
      %Matrix2051.Matrix.RoomMember{display_name: nil}
    )

    send.(%Matrix2051.Irc.Command{
      tags: %{"account" => nick},
      source: nick2nuh(nick),
      command: "JOIN",
      params: [channel, nick, nick]
    })

    case compute_topic(sup_pid, room_id) do
      nil ->
        # RPL_NOTOPIC
        send_numeric.("331", [channel])

      {topic, whotime} ->
        # RPL_TOPIC
        send_numeric.("332", [channel, topic])

        case whotime do
          nil ->
            nil

          {who, time} ->
            # RPL_TOPICWHOTIME
            send_numeric.("333", [channel, who, Integer.to_string(div(time, 1000))])
        end
    end

    # send RPL_NAMREPLY
    overhead =
      make_numeric.("353", ["=", channel, ""]) |> Matrix2051.Irc.Command.format() |> byte_size()

    Matrix2051.MatrixClient.State.room_members(state, room_id)
    |> Enum.map(fn {user_id, _member} -> user_id <> " " end)
    |> Enum.sort()
    |> Matrix2051.Irc.WordWrap.join_tokens(512 - overhead)
    |> Enum.map(fn line ->
      line = line |> String.trim_trailing()

      if line != "" do
        # RPL_NAMREPLY
        send_numeric.("353", ["=", channel, line])
      end
    end)

    # RPL_ENDOFNAMES
    send_numeric.("366", [channel, "End of /NAMES list"])
  end

  defp close_renamed_channel(
         sup_pid,
         room_id,
         write,
         canonical_alias_sender,
         old_canonical_alias
       ) do
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.matrix_state(sup_pid)
    nick = Matrix2051.IrcConn.State.nick(irc_state)
    new_canonical_alias = Matrix2051.MatrixClient.State.room_irc_channel(state, room_id)
    send = make_send_function(sup_pid, nil, write)

    # this is a known room that got renamed; part the old channel.
    send.(%Matrix2051.Irc.Command{
      tags: %{"account" => nick},
      source: nick2nuh(nick),
      command: "PART",
      params: [
        old_canonical_alias,
        canonical_alias_sender <> " renamed this room to " <> new_canonical_alias
      ]
    })

    # Announce the rename in the new room
    send.(%Matrix2051.Irc.Command{
      source: "server",
      command: "NOTICE",
      params: [
        new_canonical_alias,
        canonical_alias_sender <> " renamed this room from " <> old_canonical_alias
      ]
    })
  end

  defp format_url(url) do
    case URI.parse(url) do
      %{scheme: "mxc", host: host, path: path} ->
        "https://#{host}/_matrix/media/r0/download/#{host}#{path}"

      _ ->
        url
    end
  end

  # Returns a function that can be used to send messages
  defp make_send_function(sup_pid, event, write) do
    writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
    state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    capabilities = Matrix2051.IrcConn.State.capabilities(state)

    write =
      write ||
        fn cmd ->
          Matrix2051.IrcConn.Writer.write_command(
            writer,
            Matrix2051.Irc.Command.downgrade(cmd, capabilities)
          )
        end

    fn cmd ->
      cmd =
        case event do
          nil ->
            cmd

          _ ->
            new_tags = %{}

            new_tags =
              case Map.get(event, "origin_server_ts") do
                nil ->
                  new_tags

                origin_server_ts ->
                  time =
                    origin_server_ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

                  Map.put(new_tags, "time", time)
              end

            new_tags =
              case Map.get(event, "event_id") do
                nil -> new_tags
                event_id -> Map.put(new_tags, "msgid", event_id)
              end

            {is_echo, new_tags} =
              case Map.get(event, "unsigned") do
                %{"transaction_id" => transaction_id} ->
                  label = Matrix2051.MatrixClient.Client.transaction_id_to_label(transaction_id)

                  if label == nil do
                    {true, new_tags}
                  else
                    {true, Map.put(new_tags, "label", label)}
                  end

                _ ->
                  {false, new_tags}
              end

            %{cmd | tags: Map.merge(cmd.tags, new_tags), is_echo: is_echo}
        end

      write.(cmd)
    end
  end

  defp send_multiline_batch(sup_pid, sender, write, event, tags, target, inner_commands) do
    writer = Matrix2051.IrcConn.Supervisor.writer(sup_pid)
    irc_state = Matrix2051.IrcConn.Supervisor.state(sup_pid)
    capabilities = Matrix2051.IrcConn.State.capabilities(irc_state)
    batch_reference_tag = Base.encode32(event["event_id"], padding: false)
    send = make_send_function(sup_pid, event, write)

    # open batch
    send.(%Matrix2051.Irc.Command{
      tags: tags,
      source: nick2nuh(sender),
      command: "BATCH",
      params: ["+" <> batch_reference_tag, "draft/multiline", target]
    })

    # send content
    Enum.map(inner_commands, fn cmd ->
      Matrix2051.IrcConn.Writer.write_command(
        writer,
        Matrix2051.Irc.Command.downgrade(
          %{cmd | tags: Map.put(cmd.tags, "batch", batch_reference_tag)},
          capabilities
        )
      )
    end)

    # close batch
    cmd = %Matrix2051.Irc.Command{
      command: "BATCH",
      params: ["-" <> batch_reference_tag]
    }

    Matrix2051.IrcConn.Writer.write_command(
      writer,
      Matrix2051.Irc.Command.downgrade(cmd, capabilities)
    )
  end

  defp nick2nuh(nick) do
    [local_name, hostname] = String.split(nick, ":", parts: 2)
    "#{nick}!#{local_name}@#{hostname}"
  end
end
