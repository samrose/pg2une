defmodule Pgtune.ConfigTest do
  use ExUnit.Case

  test "stores and retrieves config values" do
    name = :"config_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Agent.start_link(fn -> %{foo: "bar", total_ram_mb: 8192} end, name: name)

    assert Agent.get(name, &Map.get(&1, :foo)) == "bar"
    assert Agent.get(name, &Map.get(&1, :total_ram_mb)) == 8192
  end

  test "get with default returns default for missing keys" do
    name = :"config_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Agent.start_link(fn -> %{} end, name: name)

    assert Agent.get(name, &Map.get(&1, :missing, "default")) == "default"
  end

  test "put updates values" do
    name = :"config_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Agent.start_link(fn -> %{val: 1} end, name: name)

    Agent.update(name, &Map.put(&1, :val, 2))
    assert Agent.get(name, &Map.get(&1, :val)) == 2
  end
end
