defmodule Pg2une.Repo.Migrations.CreateSystemSnapshots do
  use Ecto.Migration

  def change do
    create table(:system_snapshots) do
      add :snapshot_time, :utc_datetime_usec, null: false
      add :tps, :float
      add :conn_active, :integer
      add :conn_idle, :integer
      add :buffer_hit_ratio, :float
      add :temp_bytes, :bigint
      add :latency_p50, :float
      add :latency_p95, :float
      add :latency_p99, :float
    end

    create index(:system_snapshots, [:snapshot_time])
  end
end
