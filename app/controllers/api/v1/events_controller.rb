module Api
  module V1
    class EventsController < BaseController
      def index
        events = if current_user.global_admin?
          Event.all
        else
          current_user.assigned_events
        end

        render json: {
          events: events.order(:starts_at).map { |event| event_json(event) }
        }
      end

      private

      def event_json(event)
        {
          id: event.id,
          name: event.name,
          slug: event.slug,
          starts_at: event.starts_at&.iso8601,
          ends_at: event.ends_at&.iso8601,
          timezone: event.timezone_identifier,
          location_city: event.location_city,
          logo_url: attachment_url_for(event.logo),
          banner_url: attachment_url_for(event.banner)
        }
      end

      def attachment_url_for(attachment)
        return nil unless attachment.attached?

        host = request.host_with_port
        protocol = request.protocol
        path = Rails.application.routes.url_helpers.rails_storage_proxy_path(attachment, only_path: true)
        "#{protocol}#{host}#{path}"
      rescue StandardError => e
        Rails.logger.error("Failed to generate attachment URL: #{e.message}")
        nil
      end
    end
  end
end
