defmodule Pg2une.Repo.Migrations.CreateWorkloadSnapshots do
  use Ecto.Migration

  def change do
    create table(:workload_snapshots) do
      add :snapshot_time, :utc_datetime_usec, null: false
      add :queryid, :bigint
      add :query, :text
      add :calls_delta, :integer
      add :mean_exec_time, :float
      add :total_exec_time, :float
      add :rows, :bigint
      add :shared_blks_hit, :bigint
      add :shared_blks_read, :bigint
      add :temp_blks_written, :bigint
    end

    create index(:workload_snapshots, [:snapshot_time])
    create index(:workload_snapshots, [:queryid, :snapshot_time])
  end
end
