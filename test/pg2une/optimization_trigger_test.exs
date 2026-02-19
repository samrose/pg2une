defmodule Pg2une.OptimizationTriggerTest do
  use ExUnit.Case

  test "starts and schedules polling" do
    name = :"trigger_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Pg2une.OptimizationTrigger, [], name: name)
    assert Process.alive?(pid)

    state = :sys.get_state(pid)
    assert state.last_trigger == nil

    GenServer.stop(pid)
  end
end
