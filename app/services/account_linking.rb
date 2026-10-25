# Linking a participant's GitHub or itch.io account during onboarding
# (ConnectedAccountsController). Each provider has a small OAuth client with
# the same interface: configured?, authorize_url, exchange_code,
# fetch_profile and revoke.
module AccountLinking
  class Error < StandardError; end

  CLIENTS = {
    "github" => "AccountLinking::GithubClient",
    "itch" => "AccountLinking::ItchClient"
  }.freeze

  def self.client_for(provider)
    CLIENTS.fetch(provider.to_s).constantize.new
  end

  def self.provider_name(provider)
    CLIENTS.fetch(provider.to_s).constantize::NAME
  end

  def self.available?(provider)
    CLIENTS.key?(provider.to_s) && client_for(provider).configured?
  end

  # Faraday connection shared by the clients: short timeouts, JSON in and out.
  def self.http(url)
    Faraday.new(url: url, request: { open_timeout: 5, timeout: 10 }) do |f|
      f.headers["Accept"] = "application/json"
      f.headers["User-Agent"] = "Attend (attend.hackclub.com)"
    end
  end

  def self.parse(response)
    body = response.body.presence ? JSON.parse(response.body) : {}
    raise Error, "Unexpected response (#{response.status})" unless body.is_a?(Hash)

    body
  rescue JSON::ParserError
    raise Error, "Unexpected response (#{response.status})"
  end
end
