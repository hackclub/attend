# A command every front end calls the same way: the admin UI, the JSON API and
# the MCP toolboxes each build an Operation::Context and hand it to the same
# class, so who-may-do-it and what-gets-audited live in one place instead of
# three.
#
#   result = Notes::Create.call(context, participant_event: pe, attributes: attrs)
#   result.success? ? result.value : result.code / result.message
#
# A subclass:
#   * declares the AuditLog actions it writes with `audit_actions`
#   * implements #precheck (authorize and validate, change nothing; nil when
#     clear, a failure Result otherwise) and #perform (do it, audit!, return
#     success)
#
# Rules the base enforces:
#   * a Pundit denial raises Pundit::NotAuthorizedError, which every surface
#     already turns into its own "not allowed" response
#   * an API key is refused unless the operation opts in per check
#   * an anonymized connection is refused outright
#   * #perform runs in one transaction with its audit row: a step that fails
#     part-way undoes the steps before it, so a failed Result never describes a
#     half-applied change. Anything that must not happen for a rolled-back run
#     (mail, jobs) goes in ActiveRecord.after_all_transactions_commit
#   * a successful run that wrote no audit row is a bug: it raises in
#     development and test, and is reported in production
#   * audit! only accepts an action the class declared, and
#     spec/operations/audit_actions_spec.rb holds every declared action to
#     AuditLog's enum
class ApplicationOperation
  class UnauditedWrite < StandardError; end
  class UndeclaredAuditAction < StandardError; end

  class << self
    # Runs the operation. Never raises for a refusal or a validation failure
    # (those come back as a failed Result); does raise Pundit::NotAuthorizedError.
    def call(context, **arguments)
      new(context, **arguments).call
    end

    # As .call, but validation errors propagate (ActiveRecord::RecordInvalid)
    # and any other failure raises Operation::Failure — for use inside a
    # transaction that has to roll back.
    def call!(context, **arguments)
      new(context, **arguments).call!
    end

    def audit_actions(*actions)
      @declared_audit_actions = actions.map(&:to_sym).freeze
    end

    def declared_audit_actions
      @declared_audit_actions || []
    end
  end

  attr_reader :context

  def initialize(context)
    @context = context
  end

  def call
    call!
  rescue Operation::Failure => e
    e.result
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    failure(:invalid, e.message, record: e.record)
  end

  def call!
    refusal = refuse_anonymized || precheck
    raise Operation::Failure, refusal if refusal

    result = ActiveRecord::Base.transaction do
      perform.tap { |outcome| raise Operation::Failure, outcome if outcome.failure? }
    end

    ensure_audited!
    result
  end

  # Authorize and validate without changing anything. Public so a surface can
  # ask "would this be allowed?" before it starts its own work.
  def precheck
    nil
  end

  private

  def perform
    raise NotImplementedError, "#{self.class.name} must implement #perform"
  end

  def success(value = nil) = Operation::Result.success(value)

  def failure(code, message, record: nil) = Operation::Result.failure(code, message, record: record)

  # Pundit, as the context's user. API keys have no user to ask, so they are
  # refused unless this particular check says keys may pass — today's API lets
  # an event or series key do a small, explicit set of things.
  def authorize!(record, query, api_keys: :refuse)
    if context.api_key?
      return true if api_keys == :allow

      raise Pundit::NotAuthorizedError, "API keys may not run #{self.class.name}"
    end

    context.authorize!(record, query)
  end

  def policy(record) = context.policy(record)

  # Writes the audit row for this operation and tells the context, so the
  # surface's catch-all hook (log_admin_action, audit_api_change!,
  # audit_write!) doesn't write a second one.
  #
  # Like those hooks, a failure to audit is reported rather than allowed to
  # undo the write, and raises in development and test. The context is only
  # told once the row exists: if writing it failed, the catch-all hook still
  # gets its turn, so the write is not left with no row at all.
  def audit!(action, record, changed_fields: nil, metadata: {})
    @audit_attempted = true

    unless self.class.declared_audit_actions.include?(action.to_sym)
      raise UndeclaredAuditAction, "#{self.class.name} audits #{action.inspect} without declaring it in audit_actions"
    end

    changes = changed_fields || record.previous_changes.except("created_at", "updated_at")

    # In a savepoint, so a database error here is undone on its own instead
    # of poisoning the operation's transaction and taking the write with it.
    AuditLog.transaction(requires_new: true) do
      AuditLog.log!(
        action: action,
        record: record,
        actor: context.actor,
        event: audit_event,
        changed_fields: AuditLog.redact_sensitive_fields(record, changes),
        metadata: audit_metadata(record).merge(metadata).compact
      )
    end
    context.audited!(record)
  rescue StandardError => e
    report_audit_failure(e)
  end

  def audit_event
    event = context.event
    event unless event.nil? || event.destroyed?
  end

  def audit_metadata(record)
    base = context.metadata.deep_dup
    base[:params] = SensitiveFields.redact_params(base[:params], model: record.class) if base[:params]
    base.merge(operation: self.class.name, surface: context.surface.to_s)
  end

  # A run that tried to audit and failed has already been reported by audit!.
  def ensure_audited!
    return if @audit_attempted

    report_audit_failure(UnauditedWrite.new("#{self.class.name} succeeded without writing an audit row"))
  end

  def report_audit_failure(error)
    Rails.logger.error("[Security] #{self.class.name} audit failed: #{error.class} - #{error.message}")
    Sentry.capture_exception(error) if defined?(Sentry)
    raise error if Rails.env.local?
  end

  def refuse_anonymized
    return unless context.anonymized?

    failure(:anonymized, "This connection is anonymized, so it can read data but not change it.")
  end
end
