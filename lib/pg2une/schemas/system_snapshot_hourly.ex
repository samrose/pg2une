defmodule Pg2une.Schemas.SystemSnapshotHourly do
  use Ecto.Schema

  schema "system_snapshots_hourly" do
    field :hour, :utc_datetime_usec
    field :tps_avg, :float
    field :tps_max, :float
    field :conn_active_avg, :float
    field :buffer_hit_ratio_avg, :float
    field :latency_p99_avg, :float
    field :latency_p99_max, :float
    field :sample_count, :integer
  end
end
