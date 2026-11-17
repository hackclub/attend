module Operation
  # Who is acting, and through which front end.
  #
  #   user        the person Pundit authorizes. nil for an API key.
  #   actor       who the audit row is attributed to. The user, or for an API
  #               key the person who issued it.
  #   surface     :html, :api or :mcp.
  #   event       the event the surface is working in, if any. Audit rows are
  #               filed under it.
  #   anonymized  an anonymized MCP connection. Operations refuse to run.
  #   api_key     the request authenticated with an event or series API key.
  #   pii_scope   how the surface decides "may this user see PII": against this
  #               event (:event), or against any event they hold a role on (:any).
  #               :event with no event fails closed for everyone but a global
  #               admin; a surface that means "any event" has to say :any.
  #   metadata    surface details stored on the audit row (ip, tool name...).
  #   authorizer  optional callable(record, query) replacing the plain Pundit
  #               check, for a surface that layers its own rule on top (MCP's
  #               per-connection event allowlist).
  #
  # One context lives for one request, and remembers what operations audited
  # so the surface's catch-all audit hook can stand down.
  class Context
    SURFACES = %i[html api mcp].freeze
    PII_SCOPES = %i[event any].freeze

    attr_reader :user, :actor, :surface, :event, :metadata, :pii_scope

    def initialize(surface:, user:, actor: user, event: nil, anonymized: false, api_key: false,
                   pii_scope: :event, metadata: {}, authorizer: nil)
      raise ArgumentError, "unknown surface #{surface.inspect}" unless SURFACES.include?(surface)
      raise ArgumentError, "unknown pii_scope #{pii_scope.inspect}" unless PII_SCOPES.include?(pii_scope)

      @surface = surface
      @user = user
      @actor = actor
      @event = event
      @anonymized = anonymized
      @api_key = api_key
      @pii_scope = pii_scope
      @metadata = metadata
      @authorizer = authorizer
      @audited = []
    end

    def anonymized? = @anonymized ? true : false

    def api_key? = @api_key ? true : false

    def html? = surface == :html

    def api? = surface == :api

    def mcp? = surface == :mcp

    def authorize!(record, query)
      return @authorizer.call(record, query) if @authorizer

      Pundit.authorize(user, record, query)
    end

    def policy(record)
      Pundit.policy!(user, record)
    end

    def can_view_pii?
      return false unless user
      return user.can_view_participant_pii? || false if pii_scope == :any
      # No event to judge against. User#can_view_participant_pii?(nil) would
      # answer for any event, which is the wider :any question, not this one.
      return user.global_admin? || false if event.nil?

      user.can_view_participant_pii?(event) || false
    end

    def audited!(record)
      @audited << audit_key(record)
    end

    # With a record: did an operation audit that record? Without: did any
    # operation audit anything this request?
    def audited?(record = nil)
      return @audited.any? if record.nil?

      @audited.include?(audit_key(record))
    end

    private

    def audit_key(record)
      [ record.class.name, record.id ]
    end
  end
end
