defmodule Pgtune.Schemas.OptimizerObservation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "optimizer_observations" do
    field :workload_type, :string
    field :config, :map
    field :score, :float
    field :score_type, :string
    field :baseline_metrics, :map
    field :measured_metrics, :map
    field :improvement_pct, :float
    timestamps()
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [:workload_type, :config, :score, :score_type,
                     :baseline_metrics, :measured_metrics, :improvement_pct])
    |> validate_required([:config, :score, :score_type])
    |> validate_inclusion(:score_type, ["surrogate", "live_test", "deployment"])
  end
end
