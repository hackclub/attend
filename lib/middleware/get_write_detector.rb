require "yaml"

# Records every SQL write that happens while a GET or HEAD request is being
# served, with the controller#action that issued it.
#
# A GET that writes can't be served from a read replica, and
# is usually a surprise: a page view minting a token, a render saving a record.
# The ones we know about and accept live in config/get_write_allowlist.yml,
# each with its reason. Anything else fails the spec that triggered it
# (spec/support/get_write_detector.rb).
#
# Always on in test. Elsewhere, set GET_WRITE_DETECTOR=1 to log a warning for
# each GET that writes outside the allowlist; nothing is blocked.
#
# Lives in lib/middleware (required by hand, never reloaded) because it holds
# a notification subscription and a place in the middleware stack.
module GetWriteDetector
  ALLOWLIST_PATH = File.expand_path("../../config/get_write_allowlist.yml", __dir__)
  STATE_KEY = :get_write_detector_request
  SAFE_METHODS = %w[GET HEAD].freeze

  # Row locks aren't writes to Active Record, but a hot standby refuses them
  # just the same, so they count here.
  LOCKING_READ = /\bFOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b/i
  TABLE = /\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|TRUNCATE(?:\s+TABLE)?)\s+"?([\w.]+)"?/i
  LOCKED_TABLE = /\bFROM\s+"?([\w.]+)"?/i

  Write = Struct.new(:endpoint, :http_method, :path, :table, :sql, :database, keyword_init: true) do
    def to_s
      "#{http_method} #{path} (#{endpoint}) wrote to #{table}: #{sql.squish.truncate(200)}"
    end
  end

  # What one request has written so far.
  class Tracking
    attr_reader :http_method, :path, :writes
    attr_accessor :endpoint, :jobs_running

    def initialize(http_method, path)
      @http_method = http_method
      @path = path
      @writes = []
      @jobs_running = 0
    end
  end

  # The accepted GET writes: `databases` entries accept every write to a
  # database that isn't the application's own (the job queue, the cache),
  # `global` entries match a write by the start of its SQL wherever it
  # happens, `actions` entries accept anything one controller#action writes.
  class Allowlist
    attr_reader :databases, :global, :actions

    def self.load(path = ALLOWLIST_PATH)
      data = File.exist?(path) ? YAML.safe_load_file(path) : nil
      new(**(data || {}).slice("databases", "global", "actions").transform_keys(&:to_sym))
    end

    def initialize(databases: nil, global: nil, actions: nil)
      @databases = (databases || {}).keys.to_set(&:to_s).freeze
      @global = (global || []).map { |entry| entry.fetch("sql").squish }.freeze
      @actions = (actions || {}).keys.to_set.freeze
    end

    def allowed?(write)
      database?(write.database) || action?(write.endpoint) || global?(write.sql)
    end

    # database is the name of the connection's entry in config/database.yml
    def database?(database)
      databases.include?(database.to_s)
    end

    def global?(sql)
      squished = sql.squish
      global.any? { |prefix| squished.start_with?(prefix) }
    end

    # endpoint is "controller/path#action"
    def action?(endpoint)
      actions.include?(endpoint)
    end
  end

  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless SAFE_METHODS.include?(env["REQUEST_METHOD"])

      GetWriteDetector.track(env) { @app.call(env) }
    end
  end

  # ActiveSupport::Notifications subscriber. Jobs run inline by a test's
  # perform_enqueued_jobs are not the request's own writes: in production they
  # run on a worker, which is the whole point of moving a write into one.
  #
  # Only those are let off. perform_now, and perform_later on the inline
  # adapter, run the job inside the request in production too, so what they
  # write is the request's own.
  class JobSubscriber
    def start(_name, _id, payload)
      return unless JobSubscriber.run_by_test_queue?(payload)

      GetWriteDetector.current&.then { |tracking| tracking.jobs_running += 1 }
    end

    def finish(_name, _id, payload)
      return unless JobSubscriber.run_by_test_queue?(payload)

      GetWriteDetector.current&.then { |tracking| tracking.jobs_running -= 1 }
    end

    # A job the test adapter is performing after it was queued: it carries
    # the time it was enqueued, which a job handed straight to perform_now
    # never does.
    def self.run_by_test_queue?(payload)
      payload[:adapter].is_a?(ActiveJob::QueueAdapters::TestAdapter) && payload[:job]&.enqueued_at.present?
    end
  end

  class << self
    def enabled?
      Rails.env.test? || ENV["GET_WRITE_DETECTOR"].present?
    end

    def install!(app)
      return unless enabled?

      app.config.middleware.insert_before 0, Middleware

      ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        record_sql(payload) if current
      end
      # The router has matched by now, so this names the endpoint even when
      # the request never gets as far as path_parameters being read back.
      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*, payload|
        current&.endpoint = endpoint_name(payload[:controller].to_s.delete_suffix("Controller").underscore, payload[:action])
      end
      ActiveSupport::Notifications.subscribe("perform.active_job", JobSubscriber.new)
    end

    def allowlist
      @allowlist ||= Allowlist.load
    end

    def current
      ActiveSupport::IsolatedExecutionState[STATE_KEY]
    end

    def track(env)
      tracking = Tracking.new(env["REQUEST_METHOD"], env["PATH_INFO"])
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = tracking
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = nil
      finish(tracking, env) if tracking&.writes&.any?
    end

    # Everything recorded since the last drain. Specs read this; nothing is
    # kept outside test, where a long-lived process would only grow it.
    def drain
      observed_mutex.synchronize do
        writes = observed.dup
        observed.clear
        writes
      end
    end

    def write?(sql, connection = nil)
      return true if LOCKING_READ.match?(sql)

      connection ? connection.write_query?(sql) : TABLE.match?(sql)
    end

    private

    def record_sql(payload)
      tracking = current
      return if tracking.jobs_running.positive?
      return if payload[:cached] || payload[:name] == "SCHEMA"

      sql = payload[:sql].to_s
      connection = payload[:connection]
      return unless write?(sql, connection)

      tracking.writes << Write.new(
        http_method: tracking.http_method,
        path: tracking.path,
        table: sql[TABLE, 1] || sql[LOCKED_TABLE, 1] || "(unknown)",
        sql: sql,
        database: connection&.pool&.db_config&.name
      )
    end

    def finish(tracking, env)
      endpoint = tracking.endpoint || endpoint_from(env) || "(rack) #{tracking.path}"
      tracking.writes.each { |write| write.endpoint = endpoint }

      if Rails.env.test?
        observed_mutex.synchronize { observed.concat(tracking.writes) }
      else
        tracking.writes.reject { |write| allowlist.allowed?(write) }.each do |write|
          Rails.logger.warn("[GetWriteDetector] #{write} -- not in config/get_write_allowlist.yml")
        end
      end
    end

    def endpoint_from(env)
      params = env["action_dispatch.request.path_parameters"]
      return unless params && params[:controller]

      endpoint_name(params[:controller], params[:action])
    end

    def endpoint_name(controller_path, action)
      "#{controller_path}##{action}"
    end

    def observed
      @observed ||= []
    end

    def observed_mutex
      @observed_mutex ||= Mutex.new
    end
  end
end
