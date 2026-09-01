module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_token!
      before_action :authorize_token_scope!

      attr_reader :current_user, :current_token, :current_event_from_api_key

      class_attribute :required_scope, instance_writer: false, default: nil

      # Declares the GlobalApiToken scope that reaches this controller. A
      # scoped token can call nothing else, so leaving it unset — as every
      # controller but Bans does — keeps that controller full-access only.
      def self.requires_scope(scope)
        self.required_scope = scope
      end

      private

      # Scope narrowing applies to global API tokens only: mobile tokens are a
      # signed-in human with their own permissions, and event API keys are
      # already restricted per-controller.
      def authorize_token_scope!
        return unless current_token.is_a?(GlobalApiToken)
        return if current_token.permits?(self.class.required_scope)

        render json: {
          error: "This token is limited to: #{current_token.scope_labels.join(', ')}"
        }, status: :forbidden
      end

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
