defmodule Pg2une.OptimizationTrigger do
  @moduledoc """
  Polls Anytune's fact store for `should_act(Action)` every 60 seconds.

  When the Datalog rule fires, checks that DeploymentManager is idle,
  enforces a 5-minute cooldown, then triggers optimization.
  """

  use GenServer
  require Logger

  @poll_interval 60_000
  @cooldown_seconds 300

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{last_trigger: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = check_and_trigger(state)
    schedule_poll()
    {:noreply, state}
  end

  defp check_and_trigger(state) do
    case Anytune.query(:pg2une, {:should_act, [:_]}) do
      [] ->
        state

      actions when is_list(actions) ->
        # Pick the first action
        {:should_act, [action_str]} = List.first(actions)
        action = if is_binary(action_str), do: String.to_existing_atom(action_str), else: action_str

        cond do
          not idle?() ->
            Logger.debug("OptimizationTrigger: should_act(#{action}) but DeploymentManager busy")
            state

          in_cooldown?(state.last_trigger) ->
            Logger.debug("OptimizationTrigger: should_act(#{action}) but in cooldown")
            state

          true ->
            Logger.info("OptimizationTrigger: triggering #{action} optimization")

            Task.start(fn ->
              case Pg2une.DeploymentManager.start_optimization(action) do
                {:ok, result} ->
                  Logger.info("OptimizationTrigger: optimization completed: #{inspect(result.status)}")

                {:error, reason} ->
                  Logger.error("OptimizationTrigger: optimization failed: #{inspect(reason)}")
              end
            end)

            %{state | last_trigger: System.monotonic_time(:second)}
        end
    end
  end

  defp idle? do
    Pg2une.DeploymentManager.status() == :idle
  end

  defp in_cooldown?(nil), do: false

  defp in_cooldown?(last_trigger) do
    elapsed = System.monotonic_time(:second) - last_trigger
    elapsed < @cooldown_seconds
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
