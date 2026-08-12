module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_token!

      attr_reader :current_user, :current_token, :current_event_from_api_key

      private

      def authenticate_token!
        token = extract_bearer_token

        @current_token = MobileToken.find_by_token(token)
        if @current_token
          @current_user = @current_token.user
          @current_token.touch_last_used!
          Current.user = @current_user

          # Signal to mobile app when token needs refresh
          if @current_token.needs_refresh?
            response.set_header("X-Token-Refresh-Recommended", "true")
          end
          return
        end

        global_token = GlobalApiToken.find_by_token(token)
        # Re-check global_admin at request time so a demoted owner's token
        # stops working even though the token row is still active.
        if global_token&.user&.global_admin?
          @current_token = global_token
          @current_user = global_token.user
          @current_token.touch_last_used!
          Current.user = @current_user
          return
        end

        event_token = EventApiToken.find_by_token(token)
        if event_token
          @current_event_from_api_key = event_token.event
          event_token.touch_last_used!
          return
        end

        @current_event_from_api_key = Event.find_by_api_key(token)
        if @current_event_from_api_key
          return
        end

        render json: { error: "Unauthorized" }, status: :unauthorized
      end

      def extract_bearer_token
        header = request.headers["Authorization"]
        return nil unless header&.start_with?("Bearer ")

        header.split(" ").last
      end

      def require_event_access!(event)
        unless current_user.can_access_event?(event)
          render json: { error: "Forbidden" }, status: :forbidden
        end
      end

      def render_error(message, status: :unprocessable_entity)
        render json: { error: message }, status: status
      end
    end
  end
end
