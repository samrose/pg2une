defmodule Pg2une.DeploymentManagerTest do
  use ExUnit.Case

  alias Pg2une.DeploymentManager

  setup do
    name = :"dm_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(DeploymentManager, [], name: name)
    %{pid: pid, name: name}
  end

  test "starts in idle state", %{name: name} do
    assert GenServer.call(name, :status) == :idle
  end

  test "rejects optimization when busy", %{name: name} do
    # Manually set state to non-idle
    :sys.replace_state(name, fn state ->
      %{state | state: :launching_canary, action: :holistic}
    end)

    assert {:error, {:busy, :launching_canary}} =
      GenServer.call(name, {:start_optimization, :knobs})
  end

  test "status reports current state and action", %{name: name} do
    :sys.replace_state(name, fn state ->
      %{state | state: :validating, action: :holistic}
    end)

    assert {:validating, :holistic} = GenServer.call(name, :status)
  end
end
