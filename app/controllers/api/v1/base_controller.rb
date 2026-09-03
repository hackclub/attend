module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_token!
      before_action :authorize_token_scope!

      attr_reader :current_user, :current_token, :current_event_from_api_key,
                  :current_series_from_api_key, :current_series_api_token

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

        series_token = SeriesApiToken.find_by_token(token)
        if series_token
          # Deliberately not @current_token: that reader is the mobile-token
          # contract (revoke!/refresh!), and an API key is not refreshable.
          @current_series_api_token = series_token
          @current_series_from_api_key = series_token.event_series
          series_token.touch_last_used!
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

      # True when the caller authenticated with an API key rather than a
      # person. There is no current_user on these requests, so endpoints that
      # need one have to keep them out explicitly.
      def api_key_request?
        current_event_from_api_key.present? || current_series_from_api_key.present?
      end

      # An event API key may only act on the one event it was issued for; a
      # series API key may act on every event inside its series. That breadth
      # is the whole point of a series key — one credential for a series that
      # runs many events.
      def api_key_scoped_to_event?(event)
        return true if current_event_from_api_key && current_event_from_api_key.id == event.id
        return true if current_series_from_api_key && event.event_series_id == current_series_from_api_key.id

        false
      end

      # Renders 403 and returns false when the current API key can't act on
      # `event`, so callers can `return unless require_api_key_event_scope!(...)`.
      def require_api_key_event_scope!(event)
        return true if api_key_scoped_to_event?(event)

        render json: { error: "API key is not valid for this event" }, status: :forbidden
        false
      end

      def require_event_access!(event)
        # API keys authenticate without a user. Endpoints that accept a key
        # branch on api_key_request? before reaching here; the rest need a
        # person, and would otherwise raise on nil instead of answering.
        if current_user.nil?
          render json: { error: "API key is not authorized for this action" }, status: :forbidden
          return
        end

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
