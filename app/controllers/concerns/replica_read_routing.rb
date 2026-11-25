# Controller side of ReplicaReads. Including it does two things, both only
# when ReplicaReads.enabled?:
#
# * remembers that this session (or API token) just wrote, so its next few
#   seconds of reads stay on the primary;
# * for controllers that also call `route_reads_to_replica`, runs GET and HEAD
#   actions on the reading role.
#
# `route_reads_to_replica` adds an around_action, so declare it *after* the
# authentication callbacks: the signed-in user and API tokens are then always
# loaded from the primary, and a session or token created a moment ago can't
# be missing from a lagging replica.
module ReplicaReadRouting
  extend ActiveSupport::Concern

  SESSION_KEY = "replica_reads_last_write".freeze
  ROLE_HEADER = "X-Attend-Db-Role".freeze

  included do
    class_attribute :replica_reads_routed, instance_writer: false, default: false
  end

  class_methods do
    def route_reads_to_replica
      self.replica_reads_routed = true
      around_action :with_replica_reads_role
    end
  end

  # A GET that turns out to write (or take a row lock) while on the reading
  # role is run again on the primary instead of failing, and reported so the
  # action can be fixed or added to config/get_write_allowlist.yml. So is one
  # that couldn't reach the replica at all (a restart, a failover, a rollout):
  # the primary is still there to answer it. Only when nothing has been
  # rendered yet: after that there is no clean second go.
  #
  # Anything the first pass memoized (records, Pundit's policy cache) came off
  # the replica, so it is dropped before the second pass. What the first pass
  # did outside ApplicationRecord (a job it enqueued, a cache write) is not
  # undone and happens again; the report is there so those GETs get fixed.
  def process_action(*)
    ivars_before = instance_variables
    super
  rescue StandardError => error
    raise unless replica_reads_retry?(error)

    replica_reads_report_fallback(error)
    (instance_variables - ivars_before).each { |ivar| remove_instance_variable(ivar) }
    @_replica_reads_fell_back = true
    super
  ensure
    replica_reads_remember_write if replica_reads_wrote?
  end

  private

  def with_replica_reads_role(&block)
    decision = replica_reads_decision
    response.set_header(ROLE_HEADER, decision.role.to_s) unless decision.reason == :disabled
    return yield unless decision.reading?

    @_replica_reads_reading = true
    ReplicaReads.reading(&block)
  end

  def replica_reads_decision
    return ReplicaReads::Decision.new(:writing, :fell_back) if @_replica_reads_fell_back

    ReplicaReads.decide(
      http_method: request.request_method,
      endpoint: replica_reads_endpoint,
      routed: replica_reads_routed,
      recently_wrote: -> { replica_reads_recent_write? }
    )
  end

  def replica_reads_endpoint
    "#{controller_path}##{action_name}"
  end

  def replica_reads_retry?(error)
    @_replica_reads_reading && !@_replica_reads_fell_back && !performed? &&
      (ReplicaReads.read_only_error?(error) || ReplicaReads.replica_unavailable_error?(error))
  end

  def replica_reads_report_fallback(error)
    if ReplicaReads.replica_unavailable_error?(error)
      # Not the action's fault, so no error report per request while the
      # replica is down.
      Rails.logger.warn(
        "[ReplicaReads] replica unavailable for #{replica_reads_endpoint} (#{error.class}); re-running on the primary."
      )
      return
    end

    Rails.logger.warn(
      "[ReplicaReads] #{replica_reads_endpoint} needed the primary (#{error.class}: #{error.message.truncate(200)}); " \
      "re-running there. Fix the write or add the action to config/get_write_allowlist.yml."
    )
    Sentry.capture_exception(error, extra: { replica_reads_endpoint: replica_reads_endpoint }) if defined?(Sentry)
  end

  # Any non-GET request, a GET the allowlist says writes, or one that had to
  # fall back to the primary.
  def replica_reads_wrote?
    return false unless ReplicaReads.enabled?

    @_replica_reads_fell_back ||
      !ReplicaReads::SAFE_METHODS.include?(request.request_method) ||
      ReplicaReads.writes_on_get?(replica_reads_endpoint)
  end

  # API controllers have no session to speak of; they return something that
  # identifies the caller (see Api::V1::BaseController) and the mark goes in
  # the cache instead.
  def replica_reads_principal
    nil
  end

  def replica_reads_remember_write
    if (principal = replica_reads_principal)
      Rails.cache.write(ReplicaReads.last_write_cache_key(principal), Time.current.to_f, expires_in: ReplicaReads.sticky_window)
    elsif !session.empty?
      session[SESSION_KEY] = Time.current.to_f
    end
  rescue StandardError => error
    # Never let bookkeeping take down a request that otherwise worked.
    Rails.logger.warn("[ReplicaReads] could not record last write: #{error.class}: #{error.message}")
  end

  def replica_reads_recent_write?
    last_write = if (principal = replica_reads_principal)
      Rails.cache.read(ReplicaReads.last_write_cache_key(principal))
    else
      session[SESSION_KEY]
    end

    last_write.present? && Time.zone.at(last_write.to_f) > ReplicaReads.sticky_window.ago
  end
end
