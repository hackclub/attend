module Api
  module V1
    class EventsController < BaseController
      # Reported when access is inherited rather than granted on the event
      # itself. Neither is an EventRoleAssignment role; both act as event
      # admins, and both outrank any stored role.
      INHERITED_GLOBAL_ROLE = "global_admin".freeze
      INHERITED_SERIES_ROLE = "series_member".freeze

      # Someone can hold several roles on one event, so `role` reports the one
      # with the widest access. Clients should key behaviour off the explicit
      # capability flags rather than off this string.
      ROLE_PRECEDENCE = %w[event_admin safeguarding_lead ops limited read_only].freeze

      def index
        events = if current_user.global_admin?
          Event.all
        else
          current_user.assigned_events
        end

        render json: {
          events: events.with_attached_logo.with_attached_banner
                        .order(:starts_at).map { |event| event_json(event) }
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
          banner_url: attachment_url_for(event.banner),
          # The caller's standing on this event, so a client can adapt its UI up
          # front instead of discovering restrictions through error responses.
          role: role_for(event),
          can_view_participant_pii: can_view_participant_pii?(event)
        }
      end

      def role_for(event)
        return INHERITED_GLOBAL_ROLE if current_user.global_admin?
        return INHERITED_SERIES_ROLE if series_member?(event)

        roles = roles_for(event)
        ROLE_PRECEDENCE.find { |role| roles.include?(role) } || roles.first
      end

      # Mirrors User#can_view_participant_pii? against the preloaded roles, so a
      # long event list doesn't cost two queries per row on app launch.
      def can_view_participant_pii?(event)
        return true if current_user.global_admin?
        return true if series_member?(event)

        roles_for(event).any? { |role| EventRoleAssignment::PII_RESTRICTED_ROLES.exclude?(role) }
      end

      def series_member?(event)
        event.event_series_id.present? && member_series_ids.include?(event.event_series_id)
      end

      def roles_for(event)
        roles_by_event_id.fetch(event.id, [])
      end

      def roles_by_event_id
        @roles_by_event_id ||= current_user.event_role_assignments
          .pluck(:event_id, :role)
          .each_with_object({}) { |(event_id, role), acc| (acc[event_id] ||= []) << role }
      end

      def member_series_ids
        @member_series_ids ||= current_user.series_role_assignments.pluck(:event_series_id).to_set
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
