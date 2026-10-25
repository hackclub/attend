module Airtable
  # Airtable OAuth integration (https://airtable.com/developers/web/api/oauth-reference):
  # authorization code flow with PKCE, plus the client secret as Basic auth on
  # the token endpoint. Access tokens last an hour and refresh tokens 60 days;
  # every refresh rotates both, so a refresh token only works once — see
  # AirtableConnection#fresh_access_token! for why that needs a lock.
  class Oauth
    AUTHORIZE_URL = "https://airtable.com/oauth2/v1/authorize".freeze
    TOKEN_PATH = "/oauth2/v1/token".freeze
    # The sync endpoint needs the two write scopes; the reads list the bases
    # the organiser granted and show whose Airtable account is connected.
    SCOPE = "data.records:read data.records:write schema.bases:read schema.bases:write user.email:read".freeze

    Token = Data.define(:access_token, :refresh_token, :scope, :expires_at, :refresh_expires_at)

    def configured?
      client_id.present? && client_secret.present?
    end

    def authorize_url(state:, redirect_uri:, code_challenge:)
      params = {
        client_id: client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: SCOPE,
        state: state,
        code_challenge: code_challenge,
        code_challenge_method: "S256"
      }
      "#{AUTHORIZE_URL}?#{params.to_query}"
    end

    def exchange_code(code:, redirect_uri:, code_verifier:)
      request_token(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri, code_verifier: code_verifier)
    end

    def refresh(refresh_token)
      request_token(grant_type: "refresh_token", refresh_token: refresh_token)
    end

    # { "id" => "usr...", "email" => "..." } — email only with user.email:read.
    def whoami(access_token)
      get_json("meta/whoami", access_token)
    end

    # The bases the organiser ticked on Airtable's consent screen.
    def list_bases(access_token)
      bases = []
      offset = nil
      loop do
        body = get_json("meta/bases", access_token, offset ? { offset: offset } : {})
        bases.concat(Array(body["bases"]).map { |base| { "id" => base["id"], "name" => base["name"] } })
        offset = body["offset"]
        break if offset.blank?
      end
      bases
    end

    private

    def request_token(**form)
      response = http("https://airtable.com").post(TOKEN_PATH) do |req|
        req.headers["Authorization"] = "Basic #{Base64.urlsafe_encode64("#{client_id}:#{client_secret}")}"
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
        req.body = URI.encode_www_form(form)
      end
      body = parse(response)

      unless response.success? && body["access_token"].present?
        detail = [ body["error"], body["error_description"] ].compact_blank.join(": ").presence || "HTTP #{response.status}"
        # invalid_grant is a dead refresh token (expired, revoked, or already
        # used); the only fix is reconnecting, so say that rather than echoing
        # the OAuth error code at an organiser.
        if body["error"] == "invalid_grant" && form[:grant_type] == "refresh_token"
          raise AuthenticationError.new("The Airtable connection has expired or was revoked (#{detail}). Reconnect Airtable on the integrations page.", response: response)
        end
        raise AuthenticationError.new("Airtable sign-in failed (#{detail})", response: response) if response.status == 401
        raise Error.new("Airtable sign-in failed (#{detail})", response: response)
      end

      now = Time.current
      Token.new(
        access_token: body["access_token"],
        refresh_token: body["refresh_token"],
        scope: body["scope"],
        expires_at: now + body.fetch("expires_in", 3600).to_i.seconds,
        refresh_expires_at: now + body.fetch("refresh_expires_in", 60.days.to_i).to_i.seconds
      )
    rescue Faraday::Error => e
      raise Error, "Couldn't reach Airtable: #{e.message}"
    end

    def get_json(path, access_token, params = {})
      response = http(Client::BASE_URL).get(path, params) do |req|
        req.headers["Authorization"] = "Bearer #{access_token}"
      end
      body = parse(response)
      raise Error.new("Airtable returned HTTP #{response.status} for #{path}", response: response) unless response.success?

      body
    rescue Faraday::Error => e
      raise Error, "Couldn't reach Airtable: #{e.message}"
    end

    # Paths stay relative so Faraday keeps the /v0 prefix (see Client#table_path).
    def http(url)
      Faraday.new(url: url.end_with?("/") ? url : "#{url}/", request: { open_timeout: 5, timeout: 15 }) do |f|
        f.headers["Accept"] = "application/json"
        f.headers["User-Agent"] = "Attend (attend.hackclub.com)"
      end
    end

    def parse(response)
      body = response.body.presence ? JSON.parse(response.body) : {}
      body.is_a?(Hash) ? body : {}
    rescue JSON::ParserError
      {}
    end

    def client_id
      Rails.application.credentials.dig(:airtable, :oauth_client_id)
    end

    def client_secret
      Rails.application.credentials.dig(:airtable, :oauth_client_secret)
    end
  end
end
