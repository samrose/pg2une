defmodule Pg2une.Schemas.SystemSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "system_snapshots" do
    field :snapshot_time, :utc_datetime_usec
    field :tps, :float
    field :conn_active, :integer
    field :conn_idle, :integer
    field :buffer_hit_ratio, :float
    field :temp_bytes, :integer
    field :latency_p50, :float
    field :latency_p95, :float
    field :latency_p99, :float
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:snapshot_time, :tps, :conn_active, :conn_idle, :buffer_hit_ratio,
                     :temp_bytes, :latency_p50, :latency_p95, :latency_p99])
    |> validate_required([:snapshot_time])
  end
end
