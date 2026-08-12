require "net/http"

# Verifies Cloudflare Turnstile tokens. When no secret key is configured
# (e.g. local development), verification is skipped and treated as passing.
class TurnstileVerifier
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  def self.site_key
    Rails.application.credentials.dig(:turnstile, :site_key) || ENV["TURNSTILE_SITE_KEY"]
  end

  def self.secret_key
    Rails.application.credentials.dig(:turnstile, :secret_key) || ENV["TURNSTILE_SECRET_KEY"]
  end

  def self.configured?
    secret_key.present?
  end

  def self.verify(token, remote_ip: nil)
    return true unless configured?
    return false if token.blank?

    response = Net::HTTP.post_form(
      URI(VERIFY_URL),
      { "secret" => secret_key, "response" => token, "remoteip" => remote_ip }.compact
    )

    JSON.parse(response.body)["success"] == true
  rescue StandardError => e
    Rails.logger.error("[Turnstile] verification failed: #{e.class} #{e.message}")
    false
  end
end
