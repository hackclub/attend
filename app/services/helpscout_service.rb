class HelpscoutService
  BASE_URL = "https://api.helpscout.net/v2"

  def initialize
    @app_id = ENV["HELPSCOUT_APP_ID"] || Rails.application.credentials.dig(:helpscout, :app_id)
    @app_secret = ENV["HELPSCOUT_APP_SECRET"] || Rails.application.credentials.dig(:helpscout, :app_secret)
  end

  def update_customer_property(customer_id:, slug:, value:)
    response = authenticated_request(:patch, "/customers/#{customer_id}/properties") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = [ { op: "replace", path: "/#{slug}", value: value } ].to_json
    end

    if response.status == 204
      Rails.logger.info("[HelpScout] Updated customer #{customer_id} property #{slug}")
      true
    else
      Rails.logger.error("[HelpScout] Failed to update customer #{customer_id}: #{response.status} #{response.body}")
      false
    end
  end

  private

  def access_token
    @access_token ||= fetch_access_token
  end

  def fetch_access_token
    response = Faraday.post("#{BASE_URL}/oauth2/token") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        grant_type: "client_credentials",
        client_id: @app_id,
        client_secret: @app_secret
      }.to_json
    end

    if response.success?
      JSON.parse(response.body)["access_token"]
    else
      raise "Failed to get HelpScout access token: #{response.status} #{response.body}"
    end
  end

  def authenticated_request(method, path, &block)
    response = make_request(method, path, &block)

    if response.status == 401
      @access_token = nil
      response = make_request(method, path, &block)
    end

    response
  end

  def make_request(method, path)
    Faraday.send(method, "#{BASE_URL}#{path}") do |req|
      req.headers["Authorization"] = "Bearer #{access_token}"
      yield req if block_given?
    end
  end
end
