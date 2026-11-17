# Serving read-only requests from the Postgres read replicas.
#
# Off unless REPLICA_READS is set to a true value *and* the primary_replica
# database is configured (REPLICA_DATABASE_URL, see config/database.yml).
# With it off nothing here changes a request: no role switch, nothing stamped.
#
# With it on, GET and HEAD requests to the admin and to /api/v1 run with
# ApplicationRecord on the reading role (ReplicaReadRouting). Everything else
# stays on the primary: onboarding, the guardian portal, OAuth callbacks,
# training, wallet passes, webhooks and MCP all write on GET or need a row
# lock, and none of them include the routing concern.
#
# The role is switched on ApplicationRecord, not ActiveRecord::Base, on
# purpose. Solid Queue, Solid Cache and Solid Cable have their own connection
# classes with only a writing pool, and gems that hang models straight off
# ActiveRecord::Base (PaperTrail, Passkit, Blazer, Toolchest) resolve their
# role from Base. Base.connected_to(role: :reading) would switch all of them
# and raise ConnectionNotDefined for the ones with no reading pool; switching
# ApplicationRecord alone leaves every one of them on the primary.
module ReplicaReads
  FLAG = "REPLICA_READS".freeze
  STICKY_SECONDS_ENV = "REPLICA_READS_STICKY_SECONDS".freeze
  DEFAULT_STICKY_SECONDS = 5
  SAFE_METHODS = %w[GET HEAD].freeze

  # What a hot standby says to a row lock or a write Rails didn't catch first.
  READ_ONLY_PG_ERRORS = %w[PG::ReadOnlySqlTransaction].freeze

  Decision = Struct.new(:role, :reason) do
    def reading?
      role == :reading
    end
  end

  class << self
    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV[FLAG].presence) == true && replica_configured?
    end

    def replica_configured?
      ApplicationRecord.connection_handler
        .retrieve_connection_pool(ApplicationRecord.connection_specification_name, role: ActiveRecord.reading_role)
        .present?
    end

    # How long a session or API token keeps reading from the primary after it
    # wrote, so nobody loads a page that predates the change they just made.
    def sticky_window
      Integer(ENV[STICKY_SECONDS_ENV].presence || DEFAULT_STICKY_SECONDS, exception: false)&.seconds ||
        DEFAULT_STICKY_SECONDS.seconds
    end

    # Which role a request runs on. `routed` is whether its controller takes
    # part at all (ReplicaReadRouting), `endpoint` is "controller/path#action".
    # `recently_wrote` may be a lambda: finding out can cost a cache read, so
    # it is only asked once everything cheaper has said "replica".
    def decide(http_method:, endpoint:, routed: true, recently_wrote: false)
      return Decision.new(:writing, :disabled) unless enabled?
      return Decision.new(:writing, :not_routed) unless routed
      return Decision.new(:writing, :unsafe_method) unless SAFE_METHODS.include?(http_method.to_s.upcase)
      return Decision.new(:writing, :writes_on_get) if writes_on_get?(endpoint)
      recently_wrote = recently_wrote.call if recently_wrote.respond_to?(:call)
      return Decision.new(:writing, :recent_write) if recently_wrote

      Decision.new(:reading, :read_only)
    end

    # Actions the GET-write allowlist says write: they'd raise on the replica.
    def writes_on_get?(endpoint)
      GetWriteDetector.allowlist.action?(endpoint)
    end

    def reading(&block)
      ApplicationRecord.connected_to(role: ActiveRecord.reading_role, &block)
    end

    # Runs a deliberate write on the primary from inside a replica-routed
    # request. A plain yield everywhere else.
    def on_primary(&block)
      return yield unless reading?

      ApplicationRecord.connected_to(role: ActiveRecord.writing_role, &block)
    end

    def reading?
      ApplicationRecord.current_role == ActiveRecord.reading_role
    end

    # True for the errors that mean "this needed the primary": Rails refusing
    # a write on the reading role, or the standby itself refusing one.
    # Looks through wrappers (a view raises ActionView::Template::Error).
    def read_only_error?(error)
      5.times do
        return false if error.nil?
        return true if error.is_a?(ActiveRecord::ReadOnlyError) || READ_ONLY_PG_ERRORS.include?(error.class.name)

        error = error.cause
      end

      false
    end

    def last_write_cache_key(principal)
      "replica_reads:last_write:#{principal}"
    end
  end
end
