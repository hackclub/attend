require "omniauth-oauth2"

module OmniAuth
  module Strategies
    class HackClub < OmniAuth::Strategies::OAuth2
      # Where #remember_refresh keeps a refresh's round trip through HCA.
      REFRESH_SESSION_KEY = "hack_club_auth.refresh"

      option :name, "hack_club"

      option :client_options, {
        site: "https://auth.hackclub.com",
        authorize_url: "/oauth/authorize",
        token_url: "/oauth/token"
      }

      # A callable taking the Rack env and returning details to prefill on
      # HCA's signup form (email, first_name, last_name, ...). HCA ignores
      # them for people who already have an account.
      option :prefill, nil

      # Scopes a sign-in asks for on top of `scope` when it sends
      # `extra_scopes=<name>`, as { name => scopes }: for details only some
      # pages need, so nobody else is asked to share them.
      option :extra_scopes, {}

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
          raw_info: raw_info,
          # The scopes HCA granted this sign-in, from its token response, so
          # a sign-in that didn't ask for some can tell their claims are
          # missing because of that, not because the account has none.
          scope: access_token.params["scope"]
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

      def authorize_params
        params = super
        prefill = options.prefill&.call(env) || {}
        prefill.compact_blank.each { |key, value| params[key.to_s] = value }
        if (extra = options.extra_scopes[request.params["extra_scopes"].to_s])
          params[:scope] = [ params[:scope], extra ].compact_blank.join(" ")
        end
        params
      end

      def request_phase
        remember_refresh
        super
      end

      # OmniAuth's test mode answers the request phase itself, without
      # #request_phase, so a spec's refresh is remembered the same way.
      def mock_request_call
        remember_refresh
        super
      end

      def callback_url
        full_host + callback_path
      end

      private

      # A "refresh from your Hack Club account" button sends `refresh` with
      # the Attend path to come back to: someone already signed in to Attend
      # going through HCA to pick up details they've just changed there.
      # Kept with who that was and when, for the callback (or failure) to
      # tell its own round trip from any other sign-in. OmniAuth's `origin`
      # can't: it comes from the Referer when there's none, and stays in the
      # session when someone gives up at HCA. Each sign-in starts afresh.
      def remember_refresh
        session.delete(REFRESH_SESSION_KEY)
        return_to = request.params["refresh"].presence
        user = env["warden"]&.authenticate(scope: :user) if return_to
        return unless user

        session[REFRESH_SESSION_KEY] = { "return_to" => return_to.to_s, "user_id" => user.id, "at" => Time.now.to_i }
      end
    end
  end
end
