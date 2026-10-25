module AccountLinking
  # itch.io OAuth: authorization code flow with PKCE and no client secret
  # (https://itch.io/docs/api/oauth). Tokens don't expire. profile:games lets
  # us list the games the participant develops later, and game:view:uploads
  # lets us download their files.
  class ItchClient
    NAME = "itch.io"
    SIGN_UP_URL = "https://itch.io/register"
    SCOPE = "profile:me profile:games game:view:uploads"

    def configured?
      client_id.present?
    end

    def authorize_url(state:, redirect_uri:, code_challenge:)
      params = {
        client_id: client_id,
        scope: SCOPE,
        redirect_uri: redirect_uri,
        response_type: "code",
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: state
      }
      "https://itch.io/user/oauth?#{params.to_query}"
    end

    def exchange_code(code:, redirect_uri:, code_verifier:)
      response = AccountLinking.http("https://api.itch.io").post("/oauth/token") do |req|
        req.body = URI.encode_www_form(
          grant_type: "authorization_code",
          code: code,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri,
          client_id: client_id
        )
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      body = AccountLinking.parse(response)

      raise Error, "itch.io sign-in failed: #{body['error_description'] || body['error']}" if body["error"].present?
      raise Error, "itch.io didn't return an access token" if body["access_token"].blank?

      { access_token: body["access_token"], scope: body["scope"] }
    rescue Faraday::Error => e
      raise Error, "Couldn't reach itch.io: #{e.message}"
    end

    def fetch_profile(access_token)
      response = AccountLinking.http("https://api.itch.io").get("/profile") do |req|
        req.headers["Authorization"] = "Bearer #{access_token}"
      end
      body = AccountLinking.parse(response)
      # itch signals API errors with an errors array, whatever the status.
      raise Error, "itch.io didn't return your profile: #{Array(body['errors']).to_sentence}" if body["errors"].present?
      raise Error, "itch.io didn't return your profile (#{response.status})" unless response.success? && body["user"].is_a?(Hash)

      user = body["user"]
      {
        uid: user["id"].to_s,
        username: user["username"],
        profile: {
          "display_name" => user["display_name"],
          "avatar_url" => user["cover_url"],
          "url" => user["url"]
        }.compact
      }
    rescue Faraday::Error => e
      raise Error, "Couldn't reach itch.io: #{e.message}"
    end

    def revoke(access_token)
      AccountLinking.http("https://api.itch.io").post("/oauth/revoke") do |req|
        req.body = URI.encode_www_form(token: access_token, client_id: client_id)
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
    end

    private

    def client_id
      Rails.application.credentials.dig(:itch, :client_id)
    end
  end
end
