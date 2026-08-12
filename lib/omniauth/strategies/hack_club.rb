require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class HackClub < OmniAuth::Strategies::OAuth2
      option :name, "hack_club"

      option :client_options, {
        site: "https://auth.hackclub.com",
        authorize_url: "/oauth/authorize",
        token_url: "/oauth/token"
      }

      uid { raw_info.dig("identity", "id") }

      info do
        identity = raw_info["identity"] || {}
        first_name = raw_info["given_name"].presence || identity["first_name"].presence
        last_name = raw_info["family_name"].presence || identity["last_name"].presence
        email = raw_info["email"].presence || identity["primary_email"].presence
        {
          email: email,
          first_name: first_name,
          last_name: last_name,
          name: raw_info["name"].presence ||
                [ first_name, last_name ].compact.join(" ").presence ||
                raw_info["nickname"].presence ||
                email&.split("@")&.first,
          phone: raw_info["phone"] || raw_info["phone_number"] || identity["phone_number"]
        }
      end

      extra do
        {
          raw_info: raw_info
        }
      end

      def raw_info
        @raw_info ||= fetch_raw_info
      end

      # HCA splits the user across two endpoints: `/api/v1/me` returns the
      # identity record (id, primary_email, slack_id, verification_status,
      # ysws_eligible) but no name fields at all, while the OIDC userinfo
      # endpoint returns the standard `name`, `given_name`, `family_name`,
      # `nickname`, `birthdate` and `address` claims. Merge both so we don't
      # fall back to the email local part for display names.
      def fetch_raw_info
        identity_info = access_token.get("/api/v1/me").parsed || {}
        identity_info.merge(fetch_userinfo)
      end

      def fetch_userinfo
        parsed = access_token.get("/oauth/userinfo").parsed
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError => e
        # Names are a nice-to-have; never block sign-in on userinfo being down.
        OmniAuth.logger.warn("[hack_club] userinfo fetch failed: #{e.class}: #{e.message}")
        {}
      end

      def callback_url
        full_host + callback_path
      end
    end
  end
end
