defmodule Pgtune.Repo.Migrations.CreateOptimizerObservations do
  use Ecto.Migration

  def change do
    create table(:optimizer_observations) do
      add :workload_type, :string
      add :config, :map
      add :score, :float
      add :score_type, :string
      add :baseline_metrics, :map
      add :measured_metrics, :map
      add :improvement_pct, :float
      timestamps()
    end
  end
end
