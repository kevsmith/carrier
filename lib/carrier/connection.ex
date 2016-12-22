defmodule Carrier.Connection do

  require Logger

  alias Carrier.Messages.MqttCall
  alias Carrier.Messages.MqttCast
  alias Carrier.Messages.MqttReply

  require Record
  Record.defrecord :hostent, Record.extract(:hostent, from_lib: "kernel/include/inet.hrl")

  @moduledoc """
  Interface for the message bus on which commands communicate.
  """

  @internal_mq_username "COG_INTERNAL"
  @default_connect_timeout 5000 # 5 seconds
  @default_log_level :error

  defstruct [:id, :conn, :call_reply]

  # Note: This type is what we get from emqttc; if we change
  # underlying message buses, we can just change this
  # definition. Client code can just depend on this opaque type and
  # not need to know that we're using emqttc at all.
  @typedoc "The connection to the message bus."
  @opaque connection :: %__MODULE__{}

  @doc """
  Starts up a message bus client process using only preconfigured parameters.
  """
  @spec connect() :: {:ok, connection()} | :ignore | {:error, term()}
  def connect() do
    connect([])
  end

  @doc """
  Starts up a message bus client process.

  Additionally, logging on this connection will be done at the level
  specified in application configuration under `:carrier` -> `__MODULE__` -> `:log_level`.
  If that is not set, it defaults to the value specified in the attribute `@default_log_level`.

  By default, waits #{@default_connect_timeout} milliseconds to
  connect to the message bus. This can be overridden by passing a
  `:connect_timeout` option in `opts`.

  """
  # Again, this spec is what comes from emqttc
  @spec connect(Keyword.t()) :: {:ok, connection()} | :ignore | {:error, term()}
  def connect(opts) do
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)

    opts = opts
    |> add_connect_config
    |> add_internal_credentials

    {:ok, conn} = :emqttc.start_link(opts)

    # `emqttc:start_link/1` returns a message bus client process, but it
    # hasn't yet established a network connection to the message bus. By
    # ensuring that we only return after the process is actually connected,
    # we can simplify startup of processes that require a message bus
    # connection.
    #
    # It also means that those clients don't have to know details about
    # emqttc (like the structure of the "connected" message), so fewer
    # implementation details about our choice of message bus don't leak out.
    #
    # If we don't connect after a specified timeout, we just fail.
    receive do
      {:mqttc, ^conn, :connected} ->
        id = UUID.uuid4(:hex)
        call_reply = "carrier/call/reply/#{id}"
        :emqttc.sync_subscribe(conn, call_reply)
        {:ok, %__MODULE__{conn: conn, id: id, call_reply: call_reply}}
    after connect_timeout ->
        Logger.info("Connection not established")
        {:error, :econnrefused}
    end
  end

  @spec disconnect(%__MODULE__{}) :: :ok | atom
  def disconnect(%__MODULE__{conn: conn}) do
    :emqttc.disconnect(conn)
  end

  def subscribe(%__MODULE__{conn: conn}, topic) do
    # `:qos1` is an MQTT quality-of-service level indicating "at least
    # once delivery" of messages. Additionally, the sender blocks
    # until receiving a message acknowledging receipt of the
    # message. This provides back-pressure for the system, and
    # generally makes things easier to reason about.
    #
    # See
    # http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718101
    # for more.
    :emqttc.sync_subscribe(conn, topic, :qos1)
  end

  def unsubscribe(%__MODULE__{conn: conn}, topic) do
    :emqttc.unsubscribe(conn, topic)
  end

  @spec call(conn :: connection, call_topic :: String.t, endpoint :: String.t, payload :: map, timeout :: integer) ::
    map |
    {:error, :call_timeout} |
    {:error, reason :: any}
  def call(%__MODULE__{call_reply: reply}=conn, call_topic, endpoint, payload, timeout) when is_map(payload) do
    flush_pending(reply)

    message = %MqttCall{sender: reply, endpoint: endpoint, payload: payload}

    # Publish message (make blocking call)
    case publish(conn, message, routed_by: call_topic) do
      {:ok, _} ->
        # Wait for response
        receive do
          {:publish, ^reply, message} ->
            MqttReply.decode!(message)
        after timeout ->
            {:error, :call_timeout}
        end
    end
  end

  @spec cast(conn :: connection, cast_topic :: String.t, endpoint :: String.t, payload :: map) :: :ok | {:error, reason :: any}
  def cast(%__MODULE__{}=conn, cast_topic, endpoint, payload) when is_map(payload) do
    message = %MqttCast{endpoint: endpoint, payload: payload}
    case publish(conn, message, routed_by: cast_topic) do
      {:ok, _} ->
        :ok
      error ->
        error
    end
  end

  @doc """
  Publish a JSON object to the message bus. The object will be
  signed with the system key.

  ## Keyword Arguments

    * `:routed_by` - the topic on which to publish `message`. Required.

  """

  # Here, we assume we're being passed a Conduit-enabled struct
  # (aside: any way to verify that statically?) We'll do the encoding
  # to JSON internally
  def publish(%__MODULE__{conn: conn}, %{__struct__: _}=message, kw_args) do
    topic = Keyword.fetch!(kw_args, :routed_by)

    encoded = message.__struct__.encode!(message)
    case Keyword.fetch(kw_args, :threshold) do
      {:ok, threshold} ->
        size = byte_size(encoded)
        if size > threshold do
          Logger.warn("Message potentially too long (#{size} bytes)")
        else
          :ok
        end
      :error ->
        :ok
    end

    :emqttc.sync_publish(conn, topic, encoded, :qos1)
  end

  ########################################################################

  defp add_internal_credentials(opts) do
    opts
    |> Keyword.put(:username, @internal_mq_username)
    |> Keyword.put(:password, Application.fetch_env!(:cog, :message_queue_password))
  end

  defp add_connect_config(opts) do
    connect_opts = Application.get_env(:cog, __MODULE__)
    host = Keyword.fetch!(connect_opts, :host)
    port = Keyword.fetch!(connect_opts, :port)
    log_level = Keyword.get(connect_opts, :log_level, @default_log_level)
    host = case is_binary(host) do
             true ->
               {:ok, hostent} = :inet.gethostbyname(String.to_char_list(host))
               List.first(hostent(hostent, :h_addr_list))
             false ->
               host
           end
    updated = [{:host, host}, {:port, port}, {:logger, {:lager, log_level}} | opts]
    configure_ssl(updated, connect_opts)
  end

  # Enable SSL connections when SSL config is provided
  defp configure_ssl(opts, connect_opts) do
    case Keyword.get(connect_opts, :ssl, false) do
      false ->
        opts
      true ->
        build_ssl_config(:verify, opts, connect_opts)
      :verify ->
        build_ssl_config(:verify, opts, connect_opts)
      :unverified ->
        build_ssl_config(:unverified, opts, connect_opts)
      :no_verify ->
        build_ssl_config(:unverified, opts, connect_opts)
    end
  end

  defp build_ssl_config(kind, opts, connect_opts) do
    cacertfile = Keyword.get(connect_opts, :ssl_cert, "")
    if cacertfile == "" do
      Logger.error(":cog/Carrier.Connection/:ssl_cert config entry is missing. SSL client connections are disabled.")
      opts
    else
      ssl_opts = [crl_check: true, cacertfile: String.to_charlist(cacertfile)]
      ssl_opts = if kind == :verify do
        [{:verify, :verify_peer}|ssl_opts]
      else
        [{:verify, :verify_none}|ssl_opts]
      end
      [{:ssl, ssl_opts}|opts]
    end
  end

  # Receive and drop and pending sent messages
  # on a topic
  defp flush_pending(topic) do
    receive do
      {:publish, ^topic, _} ->
        flush_pending(topic)
    after 0 ->
        :ok
    end
  end

end
