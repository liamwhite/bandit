defmodule Bandit.WebSocket.Handler do
  @moduledoc false
  # A WebSocket handler conforming to RFC6455, structured as a ThousandIsland.Handler

  use ThousandIsland.Handler

  alias Bandit.WebSocket.{Connection, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {websock, websock_opts, connection_opts} = state.upgrade_opts

    connection_opts
    |> Keyword.take([:fullsweep_after, :max_heap_size])
    |> Enum.each(fn {key, value} -> :erlang.process_flag(key, value) end)

    connection_opts = Keyword.merge(state.opts.websocket, connection_opts)

    state =
      state
      |> Map.take([:handler_module])
      |> Map.put(:header, <<>>)
      |> Map.put(:payload, {[], 0, 0})
      |> Map.put(:mode, :header_parsing)

    case Connection.init(websock, websock_opts, connection_opts, socket) do
      {:continue, connection} ->
        case Keyword.get(connection_opts, :timeout) do
          nil -> {:continue, Map.put(state, :connection, connection)}
          timeout -> {:continue, Map.put(state, :connection, connection), {:persistent, timeout}}
        end

      {:error, reason, connection} ->
        {:error, reason, Map.put(state, :connection, connection)}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    try_parse_frame(data, socket, state)
  end

  defp try_parse_frame(data, socket, %{mode: :header_parsing} = state) do
    state = %{state | header: state.header <> data}
    max_frame_size = Keyword.get(state.connection.opts, :max_frame_size, 0)

    case Frame.header_length(state.header, max_frame_size) do
      {:ok, {header_length, required_length}} ->
        payload_length = byte_size(state.header) - header_length

        header = binary_part(state.header, 0, header_length)
        payload = binary_part(state.header, header_length, payload_length)

        try_parse_frame(<<>>, socket, %{
          state
          | header: header,
            payload: {payload, payload_length, required_length},
            mode: :payload_parsing
        })

      {:error, message} ->
        {:error, {:deserializing, message}, state}

      :more ->
        {:continue, %{state | header: state.header}}
    end
  end

  defp try_parse_frame(data, socket, %{mode: :payload_parsing} = state) do
    {payload, payload_length, required_length} = state.payload

    payload = [payload | data]
    payload_length = payload_length + byte_size(data)

    if payload_length >= required_length do
      payload = IO.iodata_to_binary(payload)
      header_and_payload = state.header <> binary_part(payload, 0, required_length)
      next_header = binary_part(payload, required_length, byte_size(payload) - required_length)

      state = %{state | header: next_header, payload: {[], 0, 0}, mode: :header_parsing}

      parse_frame(header_and_payload, socket, state)
    else
      {:continue, %{state | payload: {payload, payload_length, required_length}}}
    end
  end

  defp parse_frame(header_and_payload, socket, state) do
    max_frame_size = Keyword.get(state.connection.opts, :max_frame_size, 0)

    case Frame.deserialize(header_and_payload, max_frame_size) do
      {{:ok, frame}, <<>>} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:continue, connection} ->
            try_parse_frame(<<>>, socket, %{state | connection: connection})

          {:close, connection} ->
            {:close, %{state | connection: connection}}

          {:error, reason, connection} ->
            {:error, reason, %{state | connection: connection}}
        end
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(socket, %{connection: connection}),
    do: Connection.handle_close(socket, connection)

  def handle_close(_socket, _state), do: :ok

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state), do: Connection.handle_shutdown(socket, state.connection)

  @impl ThousandIsland.Handler
  def handle_error(reason, socket, state),
    do: Connection.handle_error(reason, socket, state.connection)

  @impl ThousandIsland.Handler
  def handle_timeout(socket, state), do: Connection.handle_timeout(socket, state.connection)

  def handle_info({:plug_conn, :sent}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  def handle_info(msg, {socket, state}) do
    case Connection.handle_info(msg, socket, state.connection) do
      {:continue, connection_state} ->
        {:noreply, {socket, %{state | connection: connection_state}}, socket.read_timeout}

      {:error, reason, connection_state} ->
        {:stop, reason, {socket, %{state | connection: connection_state}}}
    end
  end
end
