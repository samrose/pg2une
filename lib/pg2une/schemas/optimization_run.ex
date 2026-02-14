defmodule Pg2une.Schemas.OptimizationRun do
  use Ecto.Schema
  import Ecto.Changeset

  schema "optimization_runs" do
    field :action, :string
    field :status, :string
    field :config, :map
    field :baseline_metrics, :map
    field :result_metrics, :map
    field :improvement_pct, :float
    field :deployment_state, :string
    field :canary_workload_id, :string
    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:action, :status, :config, :baseline_metrics, :result_metrics,
                     :improvement_pct, :deployment_state, :canary_workload_id])
    |> validate_required([:action, :status])
    |> validate_inclusion(:action, ["knobs", "queries", "holistic"])
    |> validate_inclusion(:status, ["running", "promoted", "rolled_back", "failed"])
  end
end
