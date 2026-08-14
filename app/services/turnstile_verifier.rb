require "net/http"

# Verifies Cloudflare Turnstile tokens against the siteverify API.
#
# A successful `success: true` alone is not enough: a token minted for a
# different form, or on a different site using the same sitekey, also comes back
# successful. So we additionally pin the action and the hostname, per
# https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
#
# Verification is skipped only in local development and test, where there is
# usually no secret to check against. In any deployed environment a missing
# secret makes verification *fail*, rather than waving every request through.
class TurnstileVerifier
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  # Cloudflare documents tokens as up to 2048 characters; anything longer is not
  # a token we minted, so reject it without spending a siteverify call.
  MAX_TOKEN_LENGTH = 2048

  # siteverify is in the request path for the guardian portal and the public
  # incident report form. Without a timeout, Net::HTTP would wait indefinitely
  # and hold the Puma thread with it.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class << self
    def site_key
      Rails.application.credentials.dig(:turnstile, :site_key) || ENV["TURNSTILE_SITE_KEY"]
    end

    def secret_key
      Rails.application.credentials.dig(:turnstile, :secret_key) || ENV["TURNSTILE_SECRET_KEY"]
    end

    def configured?
      secret_key.present?
    end

    # True when there is no secret and we are running locally, i.e. the only
    # situation where skipping the challenge is the intended behaviour.
    def skipped?
      !configured? && Rails.env.local?
    end

    # The hostnames a token is allowed to have been solved on. Set
    # TURNSTILE_HOSTNAMES to override; otherwise this is the app's own host,
    # plus the loopback names in local development.
    def expected_hostnames
      configured = ENV["TURNSTILE_HOSTNAMES"].to_s.split(",").map(&:strip).reject(&:blank?)
      return configured.to_set if configured.any?

      hosts = [ app_host ].compact
      hosts += [ "localhost", "127.0.0.1" ] if Rails.env.local?
      hosts.to_set
    end

    def verify(token, remote_ip: nil, action: nil)
      return true if skipped?
      return false unless configured?
      return false if token.blank? || token.length > MAX_TOKEN_LENGTH

      result = siteverify(token, remote_ip)
      return false if result.nil?

      unless result["success"] == true
        Rails.logger.warn("[Turnstile] rejected: #{Array(result["error-codes"]).join(", ").presence || "no error codes"}")
        return false
      end

      # An action is only enforced when the caller pins one, so that a form
      # without a data-action attribute is not silently unverifiable.
      if action.present? && result["action"] != action
        Rails.logger.warn("[Turnstile] rejected: action #{result["action"].inspect} did not match #{action.inspect}")
        return false
      end

      allowed = expected_hostnames
      if allowed.any? && !allowed.include?(result["hostname"])
        Rails.logger.warn("[Turnstile] rejected: hostname #{result["hostname"].inspect} not in #{allowed.to_a.inspect}")
        return false
      end

      true
    end

    private

    def app_host
      ENV["APP_HOST"].presence ||
        Rails.application.config.action_mailer.default_url_options&.dig(:host).presence
    end

    def siteverify(token, remote_ip)
      uri = URI(VERIFY_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        { "secret" => secret_key, "response" => token, "remoteip" => remote_ip }.compact
      )

      response = http.request(request)
      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.error("[Turnstile] verification failed: #{e.class} #{e.message}")
      nil
    end
  end
end
