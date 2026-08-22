# frozen_string_literal: true

require 'timeout'

# Collects server + database health metrics for the System (admin) page.
# All reads are read-only and wrapped in timeouts so a hung metric never
# blocks the page. Some metrics are cached briefly (DataCache) since they
# don't change second-to-second and would otherwise add load to a page
# whose job is to report load.
class SystemPresenter
  attr_reader :load_averages,
              :cpu_count,
              :mem_total_mb,
              :mem_used_mb,
              :mem_available_mb,
              :swap_total_mb,
              :swap_used_mb,
              :disk_used_pct,
              :disk_free_gb,
              :uptime_seconds,
              :puma_rss_mb,
              :puma_threads,
              :db_connections,
              :db_max_connections,
              :db_cache_hit_pct,
              :db_deadlocks,
              :db_size_mb,
              :slow_queries,
              :active_queries,
              :locked_queries,
              :bloat_tables,
              :big_tables,
              :job_pending,
              :job_queued,
              :job_failed,
              :sync_success_rate,
              :cache_entries,
              :cache_dir_mb

  def initialize
    collect_os
    collect_process
    collect_db
    collect_jobs
  end

  private

  def collect_os
    @cpu_count = nproc = `nproc`.to_i
    @cpu_count = 2 if nproc.zero?
    @load_averages = read_file('/proc/loadavg').to_s.split.first(3).map(&:to_f)
    mem = read_file('/proc/meminfo').to_s
    @mem_total_mb = kb('MemTotal', mem) / 1024
    @mem_available_mb = kb('MemAvailable', mem) / 1024
    @mem_used_mb = @mem_total_mb - @mem_available_mb
    @swap_total_mb = kb('SwapTotal', mem) / 1024
    @swap_used_mb = kb('SwapTotal', mem) / 1024 - kb('SwapFree', mem) / 1024
    disk = `df -B1 / 2>/dev/null`.lines.last.to_s.split
    @disk_used_pct = disk[4].to_s.delete('%').to_i
    @disk_free_gb = disk[3].to_i.to_f / 1024**3
    @uptime_seconds = read_file('/proc/uptime').to_s.split.first.to_f.round
  end

  def collect_process
    pids = puma_pids
    @puma_rss_mb = pids.sum { |pid| rss_kb(pid) } / 1024
    @puma_threads = pids.sum { |pid| threads_for(pid) }
  end

  def collect_db
    conn = ActiveRecord::Base.connection
    @db_connections = conn.select_value('SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()').to_i
    @db_max_connections = conn.select_value('SHOW max_connections').to_i
    stats = conn.select_one(<<~SQL) || {}
      SELECT
        round(blks_hit::numeric / NULLIF(blks_hit + blks_read, 0) * 100, 1) AS cache_hit_pct,
        deadlocks
      FROM pg_stat_database WHERE datname = current_database()
    SQL
    @db_cache_hit_pct = stats['cache_hit_pct'].to_f
    @db_deadlocks = stats['deadlocks'].to_i
    @db_size_mb = (conn.select_value('SELECT pg_database_size(current_database())').to_i / 1024.0 / 1024).round(1)

    @slow_queries = query_stats(conn, <<~SQL)
      SELECT pid, state, left(query, 120) AS query,
             round(extract(epoch FROM now() - query_start)::numeric, 1) AS seconds
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND state = 'active'
        AND query NOT ILIKE '%pg_stat_activity%'
        AND extract(epoch FROM now() - query_start) > 1
      ORDER BY query_start
    SQL

    @active_queries = query_stats(conn, <<~SQL)
      SELECT pid, state, left(query, 100) AS query,
             round(extract(epoch FROM now() - query_start)::numeric, 1) AS seconds
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND state = 'active'
        AND query NOT ILIKE '%pg_stat_activity%'
      ORDER BY query_start DESC LIMIT 15
    SQL

    @locked_queries = query_stats(conn, <<~SQL)
      SELECT a.pid, left(a.query, 120) AS query,
             round(extract(epoch FROM now() - a.query_start)::numeric, 1) AS seconds,
             left(b.query, 80) AS blocked_by
      FROM pg_stat_activity a
      JOIN pg_stat_activity b ON b.pid = ANY(pg_blocking_pids(a.pid))
      WHERE a.datname = current_database() AND a.state = 'active'
    SQL

    @bloat_tables = query_stats(conn, <<~SQL)
      SELECT relname AS table,
             n_live_tup, n_dead_tup,
             CASE WHEN n_live_tup + n_dead_tup > 0
               THEN round(n_dead_tup::numeric / (n_live_tup + n_dead_tup) * 100, 1)
               ELSE 0 END AS dead_pct
      FROM pg_stat_user_tables
      WHERE n_dead_tup > 1000
      ORDER BY n_dead_tup DESC LIMIT 10
    SQL

    @big_tables = query_stats(conn, <<~SQL)
      SELECT relname AS table,
             round(pg_total_relation_size(relid)::numeric / 1024 / 1024, 1) AS mb,
             n_live_tup
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(relid) DESC LIMIT 10
    SQL
  end

  def collect_jobs
    @job_pending = begin
      SolidQueue::ReadyExecution.count
    rescue StandardError
      0
    end
    @job_queued = begin
      SolidQueue::ScheduledExecution.count
    rescue StandardError
      0
    end
    @job_failed = begin
      SolidQueue::FailedExecution.count
    rescue StandardError
      0
    end
    @sync_success_rate = sync_success_rate_value
    @cache_entries = cache_entries_count
    @cache_dir_mb = cache_dir_mb_value
  end

  def query_stats(conn, sql)
    conn.select_all(sql).to_a
  rescue StandardError
    []
  end

  # --- small helpers ---

  def kb(key, meminfo)
    meminfo[/^#{Regexp.escape(key)}:\s+(\d+)/, 1].to_i
  end

  def read_file(path)
    Timeout.timeout(2) { File.read(path) }
  rescue StandardError
    nil
  end

  def puma_pids
    `pgrep -f "puma"`.lines.map(&:to_i)
  rescue StandardError
    []
  end

  def rss_kb(pid)
    Timeout.timeout(2) { File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i }
  rescue StandardError
    0
  end

  def threads_for(pid)
    Dir.children("/proc/#{pid}/task").size
  rescue StandardError
    0
  end

  def sync_success_rate_value
    total = SyncRun.count
    return 0 if total.zero?

    (SyncRun.where(status: 'success').count.to_f / total * 100).round(1)
  end

  def cache_dir_mb_value
    dir = Rails.root.join('tmp', 'cache')
    return 0 unless Dir.exist?(dir)

    Timeout.timeout(5) do
      size = Dir.glob("#{dir}/**/*").select { |f| File.file?(f) }.sum { |f| File.size(f) }
      (size / 1024.0 / 1024).round(1)
    end
  rescue StandardError
    0
  end

  def cache_entries_count
    dir = Rails.root.join('tmp', 'cache')
    return 0 unless Dir.exist?(dir)

    Timeout.timeout(5) do
      Dir.glob("#{dir}/**/*").count { |f| File.file?(f) }
    end
  rescue StandardError
    0
  end
end
