defmodule ExHashRing.HashRing.ETS do
  use GenServer

  alias ExHashRing.HashRing.Utils
  alias ExHashRing.HashRing.ETS.Config

  @compile {:inline,
            do_find_node: 4,
            do_find_nodes: 7,
            find_next_highest_item: 4,
            find_node: 2,
            find_nodes: 3}

  @default_num_replicas 512
  @default_ring_gen_gc_delay 10_000


  @type override_map :: %{atom => [binary]}

  @type generation :: non_neg_integer()

  @type ring_node :: {name :: binary(), replicas :: pos_integer()}

  @type t :: %__MODULE__{
    default_num_replicas: pos_integer(),
    nodes: [ring_node()],
    overrides: override_map(),
    previous_table: :ets.tid(),
    current_table: :ets.tid(),
    ring_gen: generation(),
    name: atom(),
    pending_gcs: %{generation() => reference()}
  }
  defstruct default_num_replicas: @default_num_replicas,
            nodes: [],
            overrides: %{},
            previous_table: nil,
            current_table: nil,
            ring_gen: 0,
            name: nil,
            pending_gcs: %{}

  ## Client

  @spec start_link(name :: atom, opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(name, opts \\ []) do
    named = Keyword.get(opts, :named, false)
    nodes = Keyword.get(opts, :nodes, [])
    overrides = Keyword.get(opts, :overrides, %{})
    num_replicas = Keyword.get(opts, :default_num_replicas, @default_num_replicas)

    gen_opts =
      if named do
        [name: name]
      else
        []
      end

    GenServer.start_link(__MODULE__, {name, nodes, num_replicas, overrides}, gen_opts)
  end

  @doc """
  Adds a node to the existing set of nodes in the ring.
  """
  @spec add_node(atom, binary, integer) :: {:ok, [{binary, integer}]} | {:error, :node_exists}
  def add_node(name, node_name, num_replicas \\ nil) do
    GenServer.call(name, {:add_node, node_name, num_replicas})
  end

  @doc """
  Adds multiple nodes to the existing set of nodes in the ring.
  """
  @spec add_nodes(name :: atom, nodes :: [binary | {binary, integer}]) :: {:ok, [{binary, integer}]} | {:error, :node_exists}
  def add_nodes(name, nodes) do
    GenServer.call(name, {:add_nodes, nodes})
  end

  @doc """
  Finds the node responsible for the given key in the specified ring.
  """
  @spec find_node(atom, binary | integer) :: {:ok, binary} | {:error, atom}
  def find_node(name, key) do
    case Config.get(name) do
      {:ok, {{table, num_nodes}, _previous_table, gen, overrides}} when num_nodes > 0 ->
        case overrides do
          %{^key => overrides} ->
            {:ok, hd(overrides)}

          _ ->
            do_find_node(table, gen, num_nodes, key)
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_ring}
    end
  end

  @doc """
  Finds the specified number of nodes responsible for the given key in the specified ring's current generation.
  """
  @spec find_nodes(atom, binary | integer, integer) :: {:ok, [binary]} | {:error, atom}
  def find_nodes(name, key, num) do
    with {:ok, {{table, num_nodes}, _previous_table, gen, overrides}} <- Config.get(name) do
      do_find_nodes_in_table(key, table, overrides, gen, num_nodes, num)
    end
  end

  @doc """
  Finds the specified number of nodes responsible for the given key in the specified ring's previous generation.
  """
  @spec find_previous_nodes(atom, binary | integer, integer) :: {:ok, [binary]} | {:error, atom}
  def find_previous_nodes(name, key, num) do
    with {:ok, {_current_table, {table, num_nodes}, gen, overrides}} <- Config.get(name) do
      do_find_nodes_in_table(key, table, overrides, gen, num_nodes, num)
    end
  end

  @doc """
  Finds the specified number of nodes responsible for the given key in the specified ring's current generation AND in
  the specified ring's previous generation.  This means that this function returns up to 2 * number of nodes requested.
  """
  @spec find_stable_nodes(atom, binary | integer, integer) :: {:ok, [binary]} | {:error, atom}
  def find_stable_nodes(name, key, num) do
    with {:ok, current_nodes} <- find_nodes(name, key, num),
         {:ok, previous_nodes} <- find_previous_nodes(name, key, num) do
      stable_nodes =
        previous_nodes
        |> Enum.reverse()
        |> Enum.reduce(Enum.reverse(current_nodes), fn node, acc ->
          if node in acc do
            acc
          else
            [node | acc]
          end
        end)
        |> Enum.reverse()

      {:ok, stable_nodes}
    end
  end

  @doc """
  Forces a garbage collection of any generations that are pending garbage collection.
  """
  @spec force_gc(atom) :: {:ok, [integer]}
  def force_gc(name) do
    GenServer.call(name, :force_gc)
  end

  @doc """
  Forces a garbage collection of a specific generation, the generation must be pending or else {:error, :not_pending}
  is returned.
  """
  @spec force_gc(atom, integer) :: :ok | {:error, :not_pending}
  def force_gc(name, ring_gen) do
    GenServer.call(name, {:force_gc, ring_gen})
  end

  @doc """
  Retrieves the current set of node names from the ring.
  """
  @spec get_nodes(atom) :: {:ok, [binary]}
  def get_nodes(name) do
    GenServer.call(name, :get_nodes)
  end

  @doc """
  Retrieves the current set of nodes as tuples of {name, replicas} from the ring.
  """
  @spec get_nodes_with_replicas(atom) :: {:ok, [{binary, integer}]}
  def get_nodes_with_replicas(name) do
    GenServer.call(name, :get_nodes_with_replicas)
  end

  @doc """
  Retrieves the current set of overrides from the ring.
  """
  @spec get_overrides(atom) :: {:ok, override_map}
  def get_overrides(name) do
    GenServer.call(name, :get_overrides)
  end

  @doc """
  Stops the GenServer holding the HashRing.
  """
  @spec stop(name :: atom()) :: :ok
  def stop(name) do
    GenServer.stop(name)
  end


  @doc """
  Removes a node from the ring by its name.
  """
  @spec remove_node(atom, binary) :: {:ok, [{binary, integer}]} | {:error, :node_not_exists}
  def remove_node(name, node_name) do
    GenServer.call(name, {:remove_node, node_name})
  end

  @doc """
  Atomically remove multiple nodes from the ring by name
  """
  @spec remove_nodes(atom, [binary]) :: {:ok, [{binary, integer}]} | {:error, :node_not_exists}
  def remove_nodes(name, node_names) do
    GenServer.call(name, {:remove_nodes, node_names})
  end

  @doc """
  Replaces the nodes in the ring with a new set of nodes.
  """
  @spec set_nodes(atom, [binary | {binary, integer}]) :: {:ok, [{binary, integer}]}
  def set_nodes(name, node_names) do
    GenServer.call(name, {:set_nodes, node_names})
  end

  @doc """
  Replaces the overrides in the ring with a new override map.
  """
  @spec set_overrides(atom, override_map) :: {:ok, override_map}
  def set_overrides(name, overrides) do
    GenServer.call(name, {:set_overrides, overrides})
  end

  @doc """
  Get the current ring generation
  """
  @spec get_ring_gen(atom) :: {:ok, integer} | :error
  def get_ring_gen(name) do
    with {:ok, {_current_table, _previous_table, ring_gen, _overrides}} <- Config.get(name) do
      {:ok, ring_gen}
    end
  end

  @spec schedule_ring_gen_gc(state :: t, generation :: integer()) :: t
  def schedule_ring_gen_gc(state, 0), do: state

  def schedule_ring_gen_gc(%__MODULE__{} = state, ring_gen) do
    pending_gcs =
      Map.put_new_lazy(state.pending_gcs, ring_gen, fn ->
        ring_gen_gc_delay = Application.get_env(:hash_ring, :ring_gen_gc_delay, @default_ring_gen_gc_delay)
        Process.send_after(self(), {:gc, ring_gen}, ring_gen_gc_delay)
      end)

    %__MODULE__{state | pending_gcs: pending_gcs}
  end


  ## Server

  @spec init({atom, [binary], integer, override_map}) :: {:ok, t}
  def init({name, nodes, default_num_replicas, overrides}) do
    previous_table =
      :ets.new(:previous_ring, [
        :protected,
        :ordered_set,
        {:read_concurrency, true}
      ])

    current_table =
      :ets.new(:current_ring, [
        :protected,
        :ordered_set,
        {:read_concurrency, true}
      ])

    state = %__MODULE__{
      current_table: current_table,
      previous_table: previous_table,
      default_num_replicas: default_num_replicas,
      name: name
    }

    nodes = transform_nodes(nodes, default_num_replicas)

    state =
      state
      |> update_nodes(nodes)
      |> update_overrides(overrides)

    {:ok, state}
  end

  def handle_call({:set_nodes, nodes}, _from, %__MODULE__{} = state) do
    nodes = transform_nodes(nodes, state.default_num_replicas)
    {:reply, {:ok, nodes}, update_nodes(state, nodes)}
  end

  def handle_call(
        {:add_node, node_name, nil},
        from,
        %{default_num_replicas: default_num_replicas} = state
      ) do
    handle_call({:add_node, node_name, default_num_replicas}, from, state)
  end

  def handle_call({:add_node, node_name, num_replicas}, _from, %{nodes: nodes} = state) do
    if has_node_with_name?(nodes, node_name) do
      {:reply, {:error, :node_exists}, state}
    else
      nodes = [{node_name, num_replicas} | nodes]
      {:reply, {:ok, nodes}, update_nodes(state, nodes)}
    end
  end

  def handle_call({:add_nodes, nodes}, _from, %__MODULE__{} = state) do
    nodes = transform_nodes(nodes, state.default_num_replicas)

    existing_nodes = Enum.filter(nodes, fn {name, _} ->
      has_node_with_name?(state.nodes, name)
    end)

    if Enum.empty?(existing_nodes) do
      nodes = nodes ++ state.nodes
      {:reply, {:ok, nodes}, update_nodes(state, nodes)}
    else
      {:reply, {:error, :node_exists}, state}
    end
  end

  def handle_call({:remove_node, node_name}, _from, %{nodes: nodes} = state) do
    if has_node_with_name?(nodes, node_name) do
      nodes = Enum.reject(nodes, fn {existing_node, _} -> existing_node == node_name end)
      {:reply, {:ok, nodes}, update_nodes(state, nodes)}
    else
      {:reply, {:error, :node_not_exists}, state}
    end
  end

  def handle_call({:remove_nodes, node_names}, _from, %__MODULE__{} = state) do
    unknown_nodes = Enum.reject(node_names, &has_node_with_name?(state.nodes, &1))

    if Enum.empty?(unknown_nodes) do
      nodes = Enum.reject(state.nodes, fn {name, _} -> name in node_names end)
      {:reply, {:ok, nodes}, update_nodes(state, nodes)}
    else
      {:reply, {:error, :node_not_exists}, state}
    end
  end

  def handle_call({:set_overrides, overrides}, _from, state) do
    {:reply, {:ok, overrides}, update_overrides(state, overrides)}
  end

  def handle_call(:get_overrides, _from, %{overrides: overrides} = state) do
    {:reply, {:ok, overrides}, state}
  end

  def handle_call(:get_nodes, _from, %{nodes: nodes} = state) do
    nodes = for {node_name, _} <- nodes, do: node_name
    {:reply, {:ok, nodes}, state}
  end

  def handle_call(:get_nodes_with_replicas, _from, %{nodes: nodes} = state) do
    {:reply, {:ok, nodes}, state}
  end

  def handle_call(:force_gc, _from, %{pending_gcs: pending_gcs} = state)
      when map_size(pending_gcs) == 0 do
    {:reply, {:ok, []}, state}
  end

  def handle_call(:force_gc, _from, %__MODULE__{} = state) do
    ring_gens =
      for {ring_gen, timer_ref} <- state.pending_gcs do
        Process.cancel_timer(timer_ref)
        :ok = do_ring_gen_gc(state.current_table, ring_gen)
        :ok = do_ring_gen_gc(state.previous_table, ring_gen)
        ring_gen
      end

    {:reply, {:ok, ring_gens}, %__MODULE__{state | pending_gcs: %{}}}
  end

  def handle_call({:force_gc, ring_gen}, _from, %__MODULE__{} = state) do
    {reply, pending_gcs} =
      case Map.pop(state.pending_gcs, ring_gen) do
        {nil, pending_gcs} ->
          {{:error, :not_pending}, pending_gcs}

        {timer_ref, pending_gcs} ->
          Process.cancel_timer(timer_ref)
          :ok = do_ring_gen_gc(state.current_table, ring_gen)
          :ok = do_ring_gen_gc(state.previous_table, ring_gen)
          {:ok, pending_gcs}
      end

    {:reply, reply, %__MODULE__{state | pending_gcs: pending_gcs}}
  end

  def handle_info({:gc, ring_gen}, %__MODULE__{} = state) do
    pending_gcs =
      case Map.pop(state.pending_gcs, ring_gen) do
        {nil, pending_gcs} ->
          pending_gcs

        {_stale_timer_ref, pending_gcs} ->
          :ok = do_ring_gen_gc(state.previous_table, ring_gen)
          :ok = do_ring_gen_gc(state.current_table, ring_gen)
          pending_gcs
      end

    {:noreply, %__MODULE__{state | pending_gcs: pending_gcs}}
  end

  ## Private

  defp do_find_node(table, gen, num_nodes, key) do
    hash = Utils.hash(key)

    case find_next_highest_item(table, gen, num_nodes, hash) do
      {_, node} ->
        {:ok, node}

      _ ->
        {:error, :invalid_ring}
    end
  end

  @spec do_find_nodes_in_table(
    key :: term(),
    table :: :ets.tid(),
    overrides :: override_map(),
    gen :: generation(),
    num_nodes :: non_neg_integer(),
    num :: non_neg_integer()
  ) :: {:ok, [binary]} | {:error, term}
  defp do_find_nodes_in_table(_key, _table, _overrides, _gen, 0, _num) do
    {:error, :invalid_ring}
  end

  defp do_find_nodes_in_table(_key, _table, _overrides, _gen, _num_nodes, 0) do
    {:ok, []}
  end

  defp do_find_nodes_in_table(key, table, overrides, gen, num_nodes, num) when map_size(overrides) == 0 do
    {:ok, do_find_nodes(table, gen, num_nodes, num, Utils.hash(key), [], 0)}
  end

  defp do_find_nodes_in_table(key, table, overrides, gen, num_nodes, num) do
    {found, found_length} =
      case overrides do
        %{^key => overrides} ->
          Utils.take_max(overrides, num)

        _ ->
          {[], 0}
      end

    {:ok, do_find_nodes(table, gen, num_nodes, max(num - found_length, 0), Utils.hash(key), found, found_length)}
  end

  defp do_find_nodes(_table, _gen, _num_nodes, 0, _hash, found, _found_length) do
    Enum.reverse(found)
  end

  defp do_find_nodes(_table, _gen, num_nodes, _remaining, _hash, found, num_nodes) do
    Enum.reverse(found)
  end

  defp do_find_nodes(table, gen, num_nodes, remaining, hash, found, found_length) do
    {number, node} = find_next_highest_item(table, gen, num_nodes, hash)

    if node in found do
      do_find_nodes(
        table,
        gen,
        num_nodes,
        remaining,
        number,
        found,
        found_length
      )
    else
      do_find_nodes(
        table,
        gen,
        num_nodes,
        remaining - 1,
        number,
        [node | found],
        found_length + 1
      )
    end
  end

  defp update_nodes(%__MODULE__{} = state, nodes) do
    new_ring_gen = state.ring_gen + 1

    # Get the current generation of items from the current table
    previous_items =
      state.current_table
      |> :ets.match({{state.ring_gen, :"$1"}, :"$2"})
      |> Enum.map(fn [hash, name] ->
        {{new_ring_gen, hash}, name}
      end)

    # Write the previous items into the previous table for this generation
    :ets.insert(state.previous_table, previous_items)

    # Generate current items for the current table
    current_items =
      nodes
      |> Utils.gen_items()
      |> Enum.map(fn {hash, name} ->
        {{new_ring_gen, hash}, name}
      end)

    # Write the current items into the current table for this generation
    :ets.insert(state.current_table, current_items)

    # Update the configuration to atomically cut over to the new generation
    config = {
      {state.current_table, length(nodes)},
      {state.previous_table, length(state.nodes)},
      new_ring_gen,
      state.overrides
    }

    Config.set(state.name, self(), config)

    # Schedule the previous generation for cleanup
    state = schedule_ring_gen_gc(state, state.ring_gen)

    # Update and return the state
    %__MODULE__{state | ring_gen: new_ring_gen, nodes: nodes}
  end

  defp update_overrides(%__MODULE__{} = state, overrides) do
    # Remove any empty overrides
    overrides =
      Enum.reduce(overrides, %{}, fn
        {_, []}, acc ->
          acc

        {k, v}, acc ->
          Map.put(acc, k, v)
      end)

    # Update the current configuration
    case Config.get(state.name) do
      {:ok, {current_table, previous_table, gen, _old_overrides}} ->
        Config.set(state.name(), self(), {current_table, previous_table, gen, overrides})

      _ ->
        current_table = {state.current_table, length(state.nodes)}
        previous_table = {state.previous_table, 0}
        Config.set(state.name(), self(), {current_table, previous_table, state.ring_gen, overrides})
    end

    # Update and return the state
    %__MODULE__{state | overrides: overrides}
  end

  defp do_ring_gen_gc(table, ring_gen) do
    :ets.match_delete(table, {{ring_gen, :_}, :_})
    :ok
  end

  defp find_next_highest_item(_table, _ring_gen, 0, _hash) do
    nil
  end

  defp find_next_highest_item(table, ring_gen, _num_nodes, hash) do
    key =
      case :ets.next(table, {ring_gen, hash}) do
        {^ring_gen, _number} = key ->
          key

        _ ->
          :ets.next(table, {ring_gen, -1})
      end

    case :ets.lookup(table, key) do
      [{{^ring_gen, number}, node}] ->
        {number, node}

      _ ->
        nil
    end
  end

  defp has_node_with_name?(nodes, node_name) do
    Enum.any?(nodes, &match?({^node_name, _}, &1))
  end

  defp transform_nodes(nodes, default_num_replicas) do
    Enum.map(nodes, fn
      {_node, _num_replicas} = item ->
        item

      node ->
        {node, default_num_replicas}
    end)
  end
end
