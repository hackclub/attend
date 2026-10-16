module AccountLinking
  # GitHub OAuth App (not a GitHub App, whose user tokens expire after eight
  # hours). read:user is enough to identify the account and, with the token,
  # read public repos later at a higher rate limit.
  class GithubClient
    NAME = "GitHub"
    SIGN_UP_URL = "https://github.com/signup"
    SCOPE = "read:user"

    def configured?
      client_id.present? && client_secret.present?
    end

    # PKCE on top of the client secret, as for itch.io.
    def authorize_url(state:, redirect_uri:, code_challenge:)
      params = {
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: SCOPE,
        state: state,
        allow_signup: true,
        code_challenge: code_challenge,
        code_challenge_method: "S256"
      }
      "https://github.com/login/oauth/authorize?#{params.to_query}"
    end

    def exchange_code(code:, redirect_uri:, code_verifier:)
      response = AccountLinking.http("https://github.com").post("/login/oauth/access_token") do |req|
        req.body = URI.encode_www_form(
          client_id: client_id,
          client_secret: client_secret,
          code: code,
          redirect_uri: redirect_uri,
          code_verifier: code_verifier
        )
        req.headers["Content-Type"] = "application/x-www-form-urlencoded"
      end
      body = AccountLinking.parse(response)

      # GitHub reports a bad or expired code as a 200 with an error field.
      raise Error, "GitHub sign-in failed: #{body['error_description'] || body['error']}" if body["error"].present?
      raise Error, "GitHub didn't return an access token" if body["access_token"].blank?

      { access_token: body["access_token"], scope: body["scope"] }
    rescue Faraday::Error => e
      raise Error, "Couldn't reach GitHub: #{e.message}"
    end

    def fetch_profile(access_token)
      response = AccountLinking.http("https://api.github.com").get("/user") do |req|
        req.headers["Authorization"] = "Bearer #{access_token}"
        req.headers["Accept"] = "application/vnd.github+json"
        req.headers["X-GitHub-Api-Version"] = "2022-11-28"
      end
      raise Error, "GitHub didn't return your profile (#{response.status})" unless response.success?

      user = AccountLinking.parse(response)
      {
        uid: user["id"].to_s,
        username: user["login"],
        profile: {
          "name" => user["name"],
          "avatar_url" => user["avatar_url"],
          "url" => user["html_url"]
        }.compact
      }
    rescue Faraday::Error => e
      raise Error, "Couldn't reach GitHub: #{e.message}"
    end

    def revoke(access_token)
      AccountLinking.http("https://api.github.com").delete("/applications/#{client_id}/grant") do |req|
        req.headers["Accept"] = "application/vnd.github+json"
        req.headers["Authorization"] = "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
        req.headers["Content-Type"] = "application/json"
        req.body = { access_token: access_token }.to_json
      end
    end

    private

    def client_id
      Rails.application.credentials.dig(:github, :client_id)
    end

    def client_secret
      Rails.application.credentials.dig(:github, :client_secret)
    end
  end
end
