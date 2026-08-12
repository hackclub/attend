module Vote
  # Client for the vote.hackclub.com API. Creates DRAFT vote events from Attend events.
  # See https://vote.hackclub.com API docs.
  class Client
    BASE_URL = "https://vote.hackclub.com".freeze

    def initialize(api_key: nil)
      @api_key = api_key || ENV["VOTE_API_KEY"] || Rails.application.credentials.dig(:vote, :api_key)
    end

    def configured?
      @api_key.present?
    end

    # Fetches an event by slug. Returns the parsed body, or nil if no event
    # with that slug exists (404).
    def find_event(slug)
      response = get("/api/v1/events/#{slug}")
      response.body
    rescue Vote::Error => e
      return nil if e.status == 404

      raise
    end

    # Creates a new event in the DRAFT stage on vote.hackclub.com.
    # attributes: name:, logo_url:, background_url:, slug: (optional),
    #             vote_limit:, max_team_size:, checklist:, admins: (all optional)
    def create_event(attributes)
      payload = {
        name: attributes[:name],
        logoUrl: attributes[:logo_url],
        backgroundUrl: attributes[:background_url]
      }
      payload[:slug] = attributes[:slug] if attributes[:slug].present?
      payload[:voteLimit] = attributes[:vote_limit] if attributes[:vote_limit].present?
      payload[:maxTeamSize] = attributes[:max_team_size] if attributes[:max_team_size].present?
      payload[:checklist] = attributes[:checklist] if attributes[:checklist].present?
      payload[:admins] = attributes[:admins] if attributes[:admins].present?

      response = post("/api/v1/events", payload)
      response.body
    end

    private

    def get(path)
      log_request(:get, path)
      response = connection.get(path)
      log_response(response)
      response
    rescue Faraday::Error => e
      handle_error(e)
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |conn|
        conn.request :json
        conn.response :json
        conn.response :raise_error
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.headers["Content-Type"] = "application/json"
      end
    end

    def post(path, body)
      log_request(:post, path, body)
      response = connection.post(path, body)
      log_response(response)
      response
    rescue Faraday::Error => e
      handle_error(e)
    end

    def handle_error(error)
      status = error.response&.dig(:status)
      body = error.response&.dig(:body)
      message = body.is_a?(Hash) ? body["message"] : body

      Rails.logger.error("[Vote] API error: #{status} - #{message}")
      raise Vote::Error.new(message, response: body, status: status)
    end

    def log_request(method, path, body = nil)
      Rails.logger.info("[Vote] #{method.upcase} #{path}")
      Rails.logger.debug("[Vote] Request body: #{body.to_json}") if body
    end

    def log_response(response)
      Rails.logger.info("[Vote] Response status: #{response.status}")
      Rails.logger.debug("[Vote] Response body: #{response.body.to_json}")
    end
  end
end
