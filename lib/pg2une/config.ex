defmodule Pg2une.Config do
  @moduledoc """
  Runtime configuration agent for pg2une.

  Stores target PostgreSQL connection info, mxc coordinator URL,
  and other runtime settings.
  """

  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
  end

  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))
  def get(key, default), do: Agent.get(__MODULE__, &Map.get(&1, key, default))
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  def target_url, do: get(:target_url)
  def mxc_coordinator, do: get(:mxc_coordinator, "http://localhost:4000")
  def poll_interval, do: get(:poll_interval, 60_000)
  def total_ram_mb, do: get(:total_ram_mb, 4096)
end
