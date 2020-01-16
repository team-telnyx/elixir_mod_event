defmodule FSModEvent.Connection do
  @moduledoc """
  Connection process. A GenServer that you can plug into your own supervisor
  tree.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket

  Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  """
  use GenServer

  alias FSModEvent.Packet
  alias FSModEvent.Connection

  require Logger

  defstruct name: nil,
            host: nil,
            port: nil,
            password: nil,
            socket: nil,
            buffer: '',
            state: nil,
            sender: nil,
            jobs: %{},
            listeners: %{},
            failure_count: 0,
            caller_pid: nil

  @typep t :: %Connection{}

  @max_retries 10
  @retry_interval 1000
  @config_options [packet: 0, active: :once, mode: :list]

  @doc """
  Registers the caller process as a receiver for all the events for which the
  filter_fun returns true.
  """
  @spec start_listening(GenServer.server(), fun) :: :ok
  def start_listening(name, filter_fun \\ fn _ -> true end)

  def start_listening(name, filter_fun) when is_atom(name) do
    GenServer.cast(name, {:start_listening, self(), filter_fun})
  end

  def start_listening(name, filter_fun) when is_tuple(name) do
    GenServer.cast(via_tuple(name), {:start_listening, self(), filter_fun})
  end

  @doc """
  Unregisters the caller process as a listener.
  """
  @spec stop_listening(GenServer.server()) :: :ok
  def stop_listening(name) when is_atom(name) do
    GenServer.cast(name, {:stop_listening, self()})
  end

  def stop_listening(name) when is_tuple(name) do
    GenServer.cast(via_tuple(name), {:stop_listening, self()})
  end

  @doc """
  Starts a connection to FreeSWITCH.
  """
  @spec start(
          atom | tuple,
          String.t(),
          Integer.t(),
          String.t()
        ) :: GenServer.on_start()
  def start(name, host, port, password), do: start(name, host, port, password, nil)

  @spec start(
          atom | tuple,
          String.t(),
          Integer.t(),
          String.t(),
          pid | nil
        ) :: GenServer.on_start()
  def start(name, host, port, password, caller_pid) when is_atom(name) do
    options = [
      host: host,
      port: port,
      password: password,
      name: name,
      caller_pid: caller_pid
    ]

    GenServer.start(__MODULE__, options, name: name)
  end

  def start(name, host, port, password, caller_pid) when is_tuple(name) do
    options = [
      host: host,
      port: port,
      password: password,
      name: name,
      caller_pid: caller_pid
    ]

    GenServer.start(__MODULE__, options, name: via_tuple(name))
  end

  @doc """
  Starts and links a connection to FreeSWITCH.
  """
  @spec start_link(
          atom | tuple,
          String.t(),
          Integer.t(),
          String.t()
        ) :: GenServer.on_start()
  def start_link(name, host, port, password), do: start_link(name, host, port, password, nil)

  @spec start_link(
          atom | tuple,
          String.t(),
          Integer.t(),
          String.t(),
          pid | nil
        ) :: GenServer.on_start()
  def start_link(name, host, port, password, caller_pid) when is_atom(name) do
    options = [
      host: host,
      port: port,
      password: password,
      name: name,
      caller_pid: caller_pid
    ]

    GenServer.start_link(__MODULE__, options, name: name)
  end

  def start_link(name, host, port, password, caller_pid) when is_tuple(name) do
    options = [
      host: host,
      port: port,
      password: password,
      name: name,
      caller_pid: caller_pid
    ]

    GenServer.start_link(__MODULE__, options, name: via_tuple(name))
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-api

  For a list of available commands see: https://freeswitch.org/confluence/display/FREESWITCH/mod_commands
  """
  @spec api(GenServer.server(), String.t(), String.t()) :: FSModEvent.Packet.t()
  def api(name, command, args \\ "") do
    block_send(name, "api #{command} #{args}")
  end

  @doc """
  Executes an API command in background. Returns a Job ID. The calling process
  will receive a message like {:fs_job_result, job_id, packet} with the result.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-bgapi
  """
  @spec bgapi(GenServer.server(), String.t(), String.t()) :: String.t()
  def bgapi(name, command, args \\ "")

  def bgapi(name, command, args) when is_atom(name) do
    GenServer.call(name, {:bgapi, self(), command, args})
  end

  def bgapi(name, command, args) when is_tuple(name) do
    GenServer.call(name, {:bgapi, self(), command, args})
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-linger
  """
  @spec linger(GenServer.server()) :: FSModEvent.Packet.t()
  def linger(name) do
    block_send(name, "linger")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nolinger
  """
  @spec nolinger(GenServer.server()) :: FSModEvent.Packet.t()
  def nolinger(name) do
    block_send(name, "nolinger")
  end

  @doc """
  This will always prepend your list with "plain".

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-event
  """
  @spec event(GenServer.server(), String.t()) :: FSModEvent.Packet.t()
  def event(name, events, format \\ "plain") do
    block_send(name, "event #{format} #{events}")
  end

  @doc """
  This will always prepend your list with "plain".

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-SpecialCase-'myevents'
  """
  @spec myevents(GenServer.server(), String.t()) :: FSModEvent.Packet.t()
  def myevents(name, uuid) do
    block_send(name, "myevents plain #{uuid}")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-divert_events
  """
  @spec enable_divert_events(GenServer.server()) :: FSModEvent.Packet.t()
  def enable_divert_events(name) do
    block_send(name, "divert_events on")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-divert_events
  """
  @spec disable_divert_events(GenServer.server()) :: FSModEvent.Packet.t()
  def disable_divert_events(name) do
    block_send(name, "divert_events off")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-filter
  """
  @spec filter(GenServer.server(), String.t(), String.t()) :: FSModEvent.Packet.t()
  def filter(name, key, value \\ "") do
    block_send(name, "filter #{key} #{value}")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-filterdelete
  """
  @spec filter_delete(
          GenServer.server(),
          String.t(),
          String.t()
        ) :: FSModEvent.Packet.t()
  def filter_delete(name, key, value \\ "") do
    block_send(name, "filter delete #{key} #{value}")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendevent
  """
  @spec sendevent(
          GenServer.server(),
          String.t(),
          [{String.t(), String.t()}],
          String.t()
        ) :: FSModEvent.Packet.t()
  def sendevent(name, event, headers \\ [], body \\ "") do
    length = String.length(body)
    headers = [{"content-length", to_string(length)} | headers]
    headers = for {k, v} <- headers, do: "#{k}: #{v}"
    lines = Enum.join(["sendevent #{event}" | headers], "\n")

    payload =
      if length === 0 do
        "#{lines}"
      else
        "#{lines}\n\n#{body}"
      end

    block_send(name, payload)
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_exec(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          Integer.t(),
          String.t()
        ) :: FSModEvent.Packet.t()
  def sendmsg_exec(name, uuid, command, args \\ "", loops \\ 1, body \\ "") do
    sendmsg(
      name,
      uuid,
      "execute",
      [
        {"execute-app-name", command},
        {"execute-app-arg", args},
        {"loops", to_string(loops)}
      ],
      body
    )
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_hangup(
          GenServer.server(),
          String.t(),
          Integer.t()
        ) :: FSModEvent.Packet.t()
  def sendmsg_hangup(name, uuid, cause \\ 16) do
    sendmsg(name, uuid, "hangup", [{"hangup-cause", to_string(cause)}])
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_unicast(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          Integer.t(),
          String.t(),
          Integer.t()
        ) :: FSModEvent.Packet.t()
  def sendmsg_unicast(
        name,
        uuid,
        transport \\ "tcp",
        flags \\ "native",
        local_ip \\ "127.0.0.1",
        local_port \\ 8025,
        remote_ip \\ "127.0.0.1",
        remote_port \\ 8026
      ) do
    sendmsg(name, uuid, "unicast", [
      {"local-ip", local_ip},
      {"local-port", to_string(local_port)},
      {"remote-ip", remote_ip},
      {"remote-port", to_string(remote_port)},
      {"transport", transport},
      {"flags", flags}
    ])
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_nomedia(
          GenServer.server(),
          String.t(),
          String.t()
        ) :: FSModEvent.Packet.t()
  def sendmsg_nomedia(name, uuid, info \\ "") do
    sendmsg(name, uuid, "nomedia", [{"nomedia-uuid", info}])
  end

  @doc """
  https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-exit
  """
  @spec exit(GenServer.server()) :: FSModEvent.Packet.t()
  def exit(name) do
    block_send(name, "exit")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-log
  """
  @spec log(GenServer.server(), String.t()) :: FSModEvent.Packet.t()
  def log(name, level) do
    block_send(name, "log #{level}")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nolog
  """
  @spec nolog(GenServer.server()) :: FSModEvent.Packet.t()
  def nolog(name) do
    block_send(name, "nolog")
  end

  @doc """
  Suppress the specified type of event.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nixevent
  """
  @spec nixevent(GenServer.server(), String.t()) :: FSModEvent.Packet.t()
  def nixevent(name, events) do
    block_send(name, "nixevent #{events}")
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-noevents
  """
  @spec noevents(GenServer.server()) :: FSModEvent.Packet.t()
  def noevents(name) do
    block_send(name, "noevents")
  end

  @spec init([term]) :: {:ok, t()} | no_return
  def init(options) do
    Logger.info("Starting FS connection")
    state = apply_options_to_initial_state(options)

    case :gen_tcp.connect(state.host, state.port, @config_options) do
      {:ok, socket} ->
        Logger.info(fn -> "Connected to #{state.host}:#{state.port}" end)
        {:ok, %{state | socket: socket}}

      {:error, _reason} ->
        Logger.info(fn -> "Connection to #{state.host}:#{state.port} failed. Retrying" end)
        {:ok, %{state | failure_count: 1}, @retry_interval}
    end
  end

  @spec handle_call(
          term,
          term,
          t()
        ) ::
          {:noreply, t()}
          | {:reply, term, t()}
  def handle_call({:bgapi, caller, command, args}, _from, state) do
    id = UUID.uuid4()
    cmd_send(state.socket, "bgapi #{command} #{args}\nJob-UUID: #{id}")
    jobs = Map.put(state.jobs, id, caller)
    {:reply, id, %FSModEvent.Connection{state | jobs: jobs}}
  end

  def handle_call({:send, command}, from, state) do
    cmd_send(state.socket, command)
    {:noreply, %FSModEvent.Connection{state | sender: from}}
  end

  def handle_call(call, _from, state) do
    Logger.warn("Unknown call: #{inspect(call)}")
    {:reply, :unknown_call, state}
  end

  @spec handle_cast(
          term,
          t()
        ) :: {:noreply, t()}
  def handle_cast({:start_listening, caller, filter_fun}, state) do
    key = Base.encode64(:erlang.term_to_binary(caller))
    listeners = Map.put(state.listeners, key, %{pid: caller, filter: filter_fun})

    Process.monitor(caller)
    {:noreply, %FSModEvent.Connection{state | listeners: listeners}}
  end

  def handle_cast({:stop_listening, caller}, state) do
    key = Base.encode64(:erlang.term_to_binary(caller))
    listeners = Map.delete(state.listeners, key)
    {:noreply, %FSModEvent.Connection{state | listeners: listeners}}
  end

  def handle_cast(cast, state) do
    Logger.warn("Unknown cast: #{inspect(cast)}")
    {:noreply, state}
  end

  @spec handle_info(
          term,
          t()
        ) :: {:noreply, t()}
  def handle_info({:DOWN, _, _, pid, _}, state) do
    handle_cast({:stop_listening, pid}, state)
  end

  def handle_info(:timeout, %Connection{failure_count: failure_count} = state) do
    Logger.info(fn -> "Reconnecting after timeout" end)

    if failure_count < @max_retries do
      case :gen_tcp.connect(state.host, state.port, @config_options) do
        {:ok, _socket} ->
          Logger.info(fn -> "Reconnecting to #{state.host}:#{state.port} successful." end)
          {:noreply, %{state | failure_count: 0}}

        {:error, _reason} ->
          Logger.info(fn -> "Reconnection to #{state.host}:#{state.port} Failed. Retrying" end)
          {:noreply, %{state | failure_count: failure_count + 1}, @retry_interval}
      end
    else
      {:stop, :max_retry_exceeded, state}
    end
  end

  def handle_info({:tcp, socket, data}, state) do
    :inet.setopts(socket, active: :once)

    buffer = state.buffer ++ data

    {rest, ps} = Packet.parse(buffer)
    state = Enum.reduce(ps, state, &process/2)
    {:noreply, %FSModEvent.Connection{state | buffer: rest}}
  end

  def handle_info({:tcp_closed, _}, state) do
    Logger.info("Connection closed. Reconnecting")

    case :gen_tcp.connect(state.host, state.port, @config_options) do
      {:ok, _socket} ->
        Logger.info(fn -> "Successfully reconnected to #{state.host}:#{state.port}" end)
        new_state = %{state | failure_count: 0}
        {:noreply, new_state}

      {:error, _reason} ->
        Logger.info(fn -> "Reconnect to #{state.host}:#{state.port} failed. Retrying" end)
        new_state = %{state | failure_count: 1}
        {:noreply, new_state, @retry_interval}
    end
  end

  def handle_info(message, state) do
    Logger.warn("Unknown message: #{inspect(message)}")
    {:noreply, state}
  end

  @spec terminate(term, t()) :: :ok
  def terminate(reason, _state) do
    Logger.info("Terminating with #{inspect(reason)}")
    :ok
  end

  @spec code_change(
          term,
          t(),
          term
        ) :: {:ok, t()}
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  defp process(
         %Packet{type: "auth/request"},
         state = %FSModEvent.Connection{state: :connecting}
       ) do
    auth(state.socket, state.password)
    state
  end

  defp process(
         pkt = %Packet{type: "command/reply"},
         state = %FSModEvent.Connection{state: :connecting}
       ) do
    if pkt.success do
      Logger.debug("Authenticated: #{inspect(pkt)}")

      if not is_nil(state.caller_pid) do
        send(state.caller_pid, :authenticated)
      end

      %FSModEvent.Connection{state | state: :connected}
    else
      raise "Could not login to FS: #{inspect(pkt)}"
    end
  end

  defp process(p, %FSModEvent.Connection{state: :connecting}) do
    raise "Unexpected packet while authenticating: #{inspect(p)}"
  end

  defp process(pkt, state) do
    cond do
      # Command immediate response
      Packet.is_response?(pkt) ->
        if not is_nil(state.sender) do
          GenServer.reply(state.sender, pkt)
        end

      # Background job response
      not is_nil(pkt.job_id) ->
        if not is_nil(state.jobs[pkt.job_id]) do
          send(state.jobs[pkt.job_id], {:fs_job_result, pkt.job_id, pkt})
        end

      # Regular event
      true ->
        Enum.each(state.listeners, fn {_, v} ->
          if v.filter.(pkt) do
            send(v.pid, {:fs_event, pkt})
          end
        end)
    end

    %FSModEvent.Connection{state | sender: nil}
  end

  defp auth(socket, password) do
    cmd_send(socket, "auth #{password}")
  end

  defp sendmsg(name, uuid, command, headers, body \\ "") do
    length = String.length(body)

    headers =
      if length > 0 do
        [
          {"content-length", to_string(length)},
          {"content-type", "text/plain"}
          | headers
        ]
      else
        headers
      end

    headers = [{"call-command", command} | headers]
    headers = for {k, v} <- headers, do: "#{k}: #{v}"
    lines = Enum.join(["sendmsg #{uuid}" | headers], "\n")

    payload =
      if length === 0 do
        "#{lines}"
      else
        "#{lines}\n\n#{body}"
      end

    block_send(name, payload)
  end

  defp block_send(name, command) when is_atom(name) do
    GenServer.call(name, {:send, command})
  end

  defp block_send(name, command) when is_tuple(name) do
    GenServer.call(via_tuple(name), {:send, command})
  end

  defp cmd_send(socket, command) do
    c = "#{command}\n\n"
    Logger.debug("Sending #{c}")
    :ok = :gen_tcp.send(socket, c)
  end

  defp via_tuple(name) do
    {:via, :gproc, {:n, :l, {:freeswitch, name}}}
  end

  defp apply_options_to_initial_state(options) do
    %FSModEvent.Connection{
      name: options[:name],
      host: to_charlist(options[:host]),
      port: options[:port],
      password: options[:password],
      buffer: '',
      sender: nil,
      state: :connecting,
      jobs: %{},
      caller_pid: options[:caller_pid]
    }
  end
end
