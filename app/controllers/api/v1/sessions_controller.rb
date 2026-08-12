module Api
  module V1
    class SessionsController < ActionController::API
      before_action :authenticate_token!, only: [ :destroy, :refresh ]

      def create
        user = authenticate_user_from_session

        unless user
          render json: { error: "Invalid session or user not found" }, status: :unauthorized
          return
        end

        mobile_token = MobileToken.generate_for(
          user,
          device_name: params[:device_name]
        )

        render json: {
          token: mobile_token.token,
          expires_at: mobile_token.expires_at.iso8601,
          user: user_json(user)
        }
      end

      def destroy
        current_token.revoke!
        render json: { success: true }
      end

      def refresh
        new_token = current_token.refresh!

        if new_token
          render json: {
            token: new_token.token,
            expires_at: new_token.expires_at.iso8601,
            user: user_json(current_user)
          }
        else
          render json: { error: "Unable to refresh token" }, status: :unprocessable_entity
        end
      end

      private

      def authenticate_user_from_session
        if Rails.env.development? && params[:user_id].present?
          return User.find_by(id: params[:user_id])
        end

        # Try OAuth code exchange first
        if params[:code].present?
          return authenticate_with_oauth_code(params[:code])
        end

        # Fall back to session token
        session_token = params[:session_token]
        return nil if session_token.blank?

        decoded = Rails.application.message_verifier(:mobile_auth).verify(session_token)
        User.find_by(id: decoded[:user_id])
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        nil
      end

      def authenticate_with_oauth_code(code)
        # Exchange OAuth code for tokens with Hack Club
        # Client secret is kept server-side for security
        client_id = Rails.application.credentials.dig(:hack_club, :client_id)
        client_secret = Rails.application.credentials.dig(:hack_club, :client_secret)

        body = {
          grant_type: "authorization_code",
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: params[:redirect_uri]
        }

        # Include PKCE code_verifier if provided by mobile app
        body[:code_verifier] = params[:code_verifier] if params[:code_verifier].present?

        response = Faraday.post("https://auth.hackclub.com/oauth/token") do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = body
        end

        unless response.success?
          return nil
        end

        token_data = JSON.parse(response.body)
        access_token = token_data["access_token"]

        # Get user info from Hack Club
        user_response = Faraday.get("https://auth.hackclub.com/api/v1/me") do |req|
          req.headers["Authorization"] = "Bearer #{access_token}"
        end

        return nil unless user_response.success?

        user_info = JSON.parse(user_response.body)
        identity = user_info["identity"] || {}

        # Find or create user
        user = User.find_by(hack_club_account_id: identity["id"])
        user ||= User.find_by(email: identity["primary_email"])

        if user
          user.update(hack_club_account_id: identity["id"]) unless user.hack_club_account_id
          user
        else
          nil # Don't auto-create users for mobile - they must exist
        end
      rescue Faraday::Error, JSON::ParserError => e
        Rails.logger.error("OAuth code exchange failed: #{e.message}")
        nil
      end

      def user_json(user)
        {
          id: user.id,
          name: user.name,
          email: user.email,
          global_admin: user.global_admin?,
          is_organizer: user.global_admin? || user.event_role_assignments.exists?,
          is_participant: user.participant.present?,
          events: accessible_events(user)
        }
      end

      def accessible_events(user)
        events = if user.global_admin?
          Event.all
        else
          user.assigned_events
        end

        events.order(:starts_at).map do |event|
          {
            id: event.id,
            name: event.name,
            slug: event.slug,
            starts_at: event.starts_at&.iso8601,
            ends_at: event.ends_at&.iso8601,
            timezone: event.timezone_identifier,
            location_city: event.location_city
          }
        end
      end

      def authenticate_token!
        token = extract_bearer_token
        @current_token = MobileToken.find_by_token(token)

        unless @current_token
          render json: { error: "Unauthorized" }, status: :unauthorized
          return
        end

        @current_user = @current_token.user
      end

      def current_token
        @current_token
      end

      def current_user
        @current_user
      end

      def extract_bearer_token
        header = request.headers["Authorization"]
        return nil unless header&.start_with?("Bearer ")

        header.split(" ").last
      end
    end
  end
end
