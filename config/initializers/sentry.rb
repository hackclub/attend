Sentry.init do |config|
  config.dsn = Rails.application.credentials.dig(:sentry, :dsn)
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

  config.enabled_environments = %w[production staging development]

  config.send_default_pii = false

  # Tracing configuration
  config.traces_sampler = lambda do |sampling_context|
    transaction_context = sampling_context[:transaction_context]
    transaction_name = transaction_context[:name]

    # Skip health checks and assets
    case transaction_name
    when /health/, /assets/, /packs/
      0.0
    else
      # Sample 10% of other transactions in production
      Rails.env.production? ? 0.1 : 1.0
    end
  end

  # Instrument ActiveRecord, Net::HTTP, and Redis automatically
  config.instrumenter = :sentry

  config.before_send = lambda do |event, hint|
    if hint[:exception].is_a?(Pundit::NotAuthorizedError)
      nil
    else
      event
    end
  end
end

Rails.application.config.after_initialize do
  Sentry.configure_scope do |scope|
    scope.set_tags(app: "attend")
  end
end

class SentryContextMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    Sentry.configure_scope do |scope|
      if Current.user
        scope.set_user(id: Current.user.id)
      end

      if Current.event
        scope.set_context("event", { id: Current.event.id, name: Current.event.name })
      end

      scope.set_context("request", {
        request_id: Current.request_id,
        ip_address: anonymize_ip(Current.ip_address)
      })
    end

    @app.call(env)
  end

  private

  def anonymize_ip(ip)
    return nil if ip.blank?

    addr = IPAddr.new(ip)
    if addr.ipv4?
      addr.mask(24).to_s
    else
      addr.mask(48).to_s
    end
  rescue IPAddr::InvalidAddressError
    nil
  end
end

Rails.application.config.middleware.insert_after Sentry::Rails::CaptureExceptions, SentryContextMiddleware
