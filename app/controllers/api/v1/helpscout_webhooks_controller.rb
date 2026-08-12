module Api
  module V1
    class HelpscoutWebhooksController < ActionController::API
      before_action :verify_signature

      def create
        event = request.headers["X-HelpScout-Event"]
        unless event == "convo.created"
          head :ok
          return
        end

        customer = params[:customer] || params[:primaryCustomer]
        customer_email = customer&.dig(:email)
        customer_id = customer&.dig(:id)

        unless customer_email.present? && customer_id.present?
          Rails.logger.info("[HelpScout Webhook] No customer email/id in payload, skipping")
          head :ok
          return
        end

        Rails.logger.info("[HelpScout Webhook] convo.created from #{customer_email} (customer #{customer_id})")

        user = User.find_by(email: customer_email)
        unless user
          Rails.logger.info("[HelpScout Webhook] No Attend user found for #{customer_email}")
          head :ok
          return
        end

        attend_url = "#{attend_base_url}/admin/users/#{user.id}"
        Rails.logger.info("[HelpScout Webhook] Found user #{user.id}, setting attend-uid to #{attend_url}")

        HelpscoutService.new.update_customer_property(
          customer_id: customer_id,
          slug: "attend-uid",
          value: attend_url
        )

        head :ok
      end

      private

      def verify_signature
        secret = ENV["HELPSCOUT_WEBHOOK_SECRET"] || Rails.application.credentials.dig(:helpscout, :webhook_secret)

        if secret.blank?
          Rails.logger.error("[HelpScout Webhook] No webhook secret configured")
          head :service_unavailable
          return
        end

        signature = request.headers["X-HelpScout-Signature"]
        if signature.blank?
          Rails.logger.warn("[HelpScout Webhook] Missing signature header")
          head :unauthorized
          return
        end

        payload = request.raw_post
        computed = Base64.strict_encode64(
          OpenSSL::HMAC.digest("sha1", secret, payload)
        )

        unless ActiveSupport::SecurityUtils.secure_compare(computed, signature)
          Rails.logger.warn("[HelpScout Webhook] Invalid signature")
          head :unauthorized
        end
      end

      def attend_base_url
        ENV["ATTEND_BASE_URL"] || "https://attend.hackclub.com"
      end
    end
  end
end
