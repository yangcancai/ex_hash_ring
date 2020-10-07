defmodule ExHashRing.Config do
  use GenServer

  alias ExHashRing.{Hash, Node}

  @type t :: %__MODULE__{}

  @typedoc """
  Generations are used so that changes to the ring can be applied atomically.  Mutating the Ring in ETS requires
  multiple independent operations, all entries in the ring are identified by a configurtion generation and the only
  after all changes have been applied successfully to the Ring in ETS is the configuration's generation updated to
  point at the new entries.
  """
  @type generation :: pos_integer()

  @typedoc """
  The number of logical nodes in the ring.
  """
  @type num_nodes :: non_neg_integer()

  @typedoc """
  Overrides allow the Ring to always resolve a given key to a list of nodes.
  """
  @type override_map :: %{Hash.key() => [Node.name()]}

  @typedoc """
  Table configurations package up the table and the number of logical nodes in the authoritative generation.
  """
  @type table_config :: {:ets.tid(), num_nodes()}

  @typedoc """
  For any ring name a configuration can be looked up that will provide information about the table holding the current
  ring, the table holding the previous ring, the current generation, and any overrides that should be applied during
  lookup
  """
  @type config ::{current :: table_config(), previous :: table_config(), generation(), override_map()}

  defstruct monitored_pids: %{}

  ## Client

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Retrieves the configuration for the specified ring.
  """
  @spec get(atom) :: {:ok, config} | {:error, :no_ring}
  def get(name) do
    case :ets.lookup(__MODULE__, name) do
      [{^name, config}] ->
        {:ok, config}

      _ ->
        {:error, :no_ring}
    end
  end

  @doc """
  Sets the configuration for the specified ring.
  """
  @spec set(atom, pid, config) :: :ok
  def set(name, owner_pid, config) do
    GenServer.call(__MODULE__, {:set, name, owner_pid, config})
  end

  ## Server

  @spec init(any) :: {:ok, t}
  def init(_) do
    :ets.new(__MODULE__, [
      :protected,
      :set,
      :named_table,
      {:read_concurrency, true}
    ])

    {:ok, %__MODULE__{}}
  end

  def handle_call({:set, name, owner_pid, config}, _from, state) do
    state = monitor_ring(state, name, owner_pid)
    true = :ets.insert(__MODULE__, {name, config})
    {:reply, :ok, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, %__MODULE__{} = state) do
    monitored_pids =
      case Map.pop(state.monitored_pids, pid) do
        {nil, monitored_pids} ->
          monitored_pids

        {{^monitor_ref, name}, monitored_pids} ->
          :ets.delete(__MODULE__, name)
          monitored_pids
      end

    {:noreply, %__MODULE__{state | monitored_pids: monitored_pids}}
  end

  ## Private

  @spec monitor_ring(state :: t(), name :: binary(), owner_pid :: pid()) :: t()
  defp monitor_ring(%__MODULE__{} = state, name, owner_pid) do
    monitored_pids =
      Map.put_new_lazy(state.monitored_pids, owner_pid, fn ->
        monitor_ref = Process.monitor(owner_pid)
        {monitor_ref, name}
      end)

    %__MODULE__{state | monitored_pids: monitored_pids}
  end
end