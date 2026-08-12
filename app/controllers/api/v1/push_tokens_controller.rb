module Api
  module V1
    class PushTokensController < BaseController
      def create
        token = current_user.push_tokens.find_or_initialize_by(token: params[:token])
        token.platform = detect_platform(params[:token])

        if token.save
          render json: { success: true }
        else
          render json: { error: token.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      def destroy
        token = current_user.push_tokens.find_by(token: params[:token])

        if token&.destroy
          render json: { success: true }
        else
          render json: { error: "Token not found" }, status: :not_found
        end
      end

      private

      def detect_platform(token)
        return "expo" if token&.start_with?("ExponentPushToken")
        "unknown"
      end
    end
  end
end
