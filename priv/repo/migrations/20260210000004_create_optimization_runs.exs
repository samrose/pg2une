defmodule Pg2une.Repo.Migrations.CreateOptimizationRuns do
  use Ecto.Migration

  def change do
    create table(:optimization_runs) do
      add :action, :string
      add :status, :string
      add :config, :map
      add :baseline_metrics, :map
      add :result_metrics, :map
      add :improvement_pct, :float
      add :deployment_state, :string
      add :canary_workload_id, :string
      timestamps()
    end
  end
end
