defmodule Pg2une.Repo.Migrations.CreateSystemSnapshotsHourly do
  use Ecto.Migration

  def change do
    create table(:system_snapshots_hourly) do
      add :hour, :utc_datetime_usec, null: false
      add :tps_avg, :float
      add :tps_max, :float
      add :conn_active_avg, :float
      add :buffer_hit_ratio_avg, :float
      add :latency_p99_avg, :float
      add :latency_p99_max, :float
      add :sample_count, :integer
    end

    create unique_index(:system_snapshots_hourly, [:hour])
    create index(:system_snapshots_hourly, [:hour])
  end
end
