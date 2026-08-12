module Api
  module V1
    class PostmarkWebhooksController < ApplicationController
      skip_before_action :verify_authenticity_token
      before_action :authenticate_webhook

      def create
        case params[:RecordType]
        when "Delivery"
          handle_delivery
        when "Bounce"
          handle_bounce
        when "Open"
          handle_open
        when "Click"
          handle_click
        else
          Rails.logger.info("[Postmark Webhook] Unhandled record type: #{params[:RecordType]}")
        end

        head :ok
      end

      private

      def authenticate_webhook
        authenticate_or_request_with_http_basic("Postmark Webhooks") do |username, password|
          expected_username = ENV["POSTMARK_WEBHOOK_USERNAME"] || Rails.application.credentials.dig(:postmark, :webhook_username)
          expected_password = ENV["POSTMARK_WEBHOOK_PASSWORD"] || Rails.application.credentials.dig(:postmark, :webhook_password)

          if expected_username.blank? || expected_password.blank?
            Rails.logger.error("[Postmark Webhook] Basic auth credentials are not configured")
            false
          else
            secure_credential_compare(username, expected_username) &&
              secure_credential_compare(password, expected_password)
          end
        end
      end

      def secure_credential_compare(provided, expected)
        ActiveSupport::SecurityUtils.secure_compare(
          ::Digest::SHA256.hexdigest(provided.to_s),
          ::Digest::SHA256.hexdigest(expected.to_s)
        )
      end

      def handle_delivery
        message_id = params[:MessageID]
        return unless message_id

        email_log = EmailLog.find_by(postmark_message_id: message_id)
        unless email_log
          Rails.logger.warn("[Postmark Webhook] No email log found for message_id: #{message_id}")
          return
        end

        occurred_at = parse_timestamp(params[:DeliveredAt]) || Time.current

        EmailLog.transaction do
          unless email_log.bounced? || email_log.failed?
            email_log.update!(status: "delivered", delivered_at: occurred_at)
          end
          email_log.email_log_events.create!(
            event_type: "delivered",
            occurred_at: occurred_at,
            metadata: { recipient: params[:Recipient], server_id: params[:ServerID] }.compact
          )
        end

        Rails.logger.info("[Postmark Webhook] Delivery recorded for #{message_id}")
      rescue => e
        Rails.logger.error("[Postmark Webhook] Failed to record delivery for #{message_id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      def handle_bounce
        message_id = params[:MessageID]
        return unless message_id

        email_log = EmailLog.find_by(postmark_message_id: message_id)
        unless email_log
          Rails.logger.warn("[Postmark Webhook] No email log found for message_id: #{message_id}")
          return
        end

        occurred_at = parse_timestamp(params[:BouncedAt]) || Time.current

        EmailLog.transaction do
          email_log.update!(
            status: "bounced",
            bounced_at: occurred_at,
            bounce_type: params[:Type],
            bounce_description: params[:Description]
          )
          email_log.email_log_events.create!(
            event_type: "bounced",
            occurred_at: occurred_at,
            metadata: {
              bounce_type: params[:Type],
              type_code: params[:TypeCode],
              description: params[:Description],
              details: params[:Details]
            }.compact
          )
        end

        Rails.logger.info("[Postmark Webhook] Bounce recorded for #{message_id}: #{params[:Type]}")
      rescue => e
        Rails.logger.error("[Postmark Webhook] Failed to record bounce for #{message_id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      def handle_open
        message_id = params[:MessageID]
        return unless message_id

        email_log = EmailLog.find_by(postmark_message_id: message_id)
        unless email_log
          Rails.logger.warn("[Postmark Webhook] No email log found for message_id: #{message_id}")
          return
        end

        occurred_at = parse_timestamp(params[:ReceivedAt]) || Time.current

        EmailLog.transaction do
          unless email_log.bounced? || email_log.failed?
            email_log.update!(status: "opened", opened_at: email_log.opened_at || occurred_at)
          end
          email_log.email_log_events.create!(
            event_type: "opened",
            occurred_at: occurred_at,
            metadata: {
              user_agent: params[:UserAgent],
              geo: params[:Geo],
              platform: params[:Platform],
              client: params[:Client]
            }.compact
          )

          if email_log.emailable.is_a?(MessageDelivery)
            email_log.emailable.update!(read_at: occurred_at) unless email_log.emailable.read_at
          end
        end

        Rails.logger.info("[Postmark Webhook] Open recorded for #{message_id}")
      rescue => e
        Rails.logger.error("[Postmark Webhook] Failed to record open for #{message_id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      def handle_click
        message_id = params[:MessageID]
        return unless message_id

        email_log = EmailLog.find_by(postmark_message_id: message_id)
        unless email_log
          Rails.logger.warn("[Postmark Webhook] No email log found for message_id: #{message_id}")
          return
        end

        occurred_at = parse_timestamp(params[:ReceivedAt]) || Time.current

        email_log.email_log_events.create!(
          event_type: "link_clicked",
          occurred_at: occurred_at,
          metadata: {
            original_link: params[:OriginalLink],
            click_location: params[:ClickLocation],
            user_agent: params[:UserAgent],
            geo: params[:Geo],
            platform: params[:Platform],
            client: params[:Client]
          }.compact
        )

        Rails.logger.info("[Postmark Webhook] Click recorded for #{message_id}")
      rescue => e
        Rails.logger.error("[Postmark Webhook] Failed to record click for #{message_id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      def parse_timestamp(value)
        return nil if value.blank?
        Time.zone.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
