defmodule Pg2une.Schemas.WorkloadSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workload_snapshots" do
    field :snapshot_time, :utc_datetime_usec
    field :queryid, :integer
    field :query, :string
    field :calls_delta, :integer
    field :mean_exec_time, :float
    field :total_exec_time, :float
    field :rows, :integer
    field :shared_blks_hit, :integer
    field :shared_blks_read, :integer
    field :temp_blks_written, :integer
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:snapshot_time, :queryid, :query, :calls_delta, :mean_exec_time,
                     :total_exec_time, :rows, :shared_blks_hit, :shared_blks_read,
                     :temp_blks_written])
    |> validate_required([:snapshot_time])
  end
end
