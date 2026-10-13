module Api
  module V1
    # Global-admin only. Lets a support bot sitting in the admin help Slack
    # channel work out which events the person asking runs.
    class UsersController < BaseController
      requires_scope "support:read"
      before_action :require_global_admin!

      # Matches on the Slack ID Hack Club Auth vouches for, never the profile
      # override, and only among admin help channel members.
      def lookup
        slack_id = params[:slack_id].to_s.strip.upcase
        return render_error("slack_id is required") if slack_id.blank?

        user = User.admin_help_channel_members.find_by(verified_slack_id: slack_id)
        return render json: { error: "Not found" }, status: :not_found unless user

        render json: {
          user: { id: user.id, name: user.name, email: user.email, global_admin: user.global_admin? },
          events: admin_events_for(user).map { |event| event_json(event) }
        }
      end

      private

      def require_global_admin!
        return if current_user&.global_admin?

        render json: { error: "Only global admins can look up users" }, status: :forbidden
      end

      # The same events that put someone in the admin help channel: an admin
      # help role on the event itself, or any role on its series. A global
      # admin's blanket access doesn't count, or every event would be listed.
      def admin_events_for(user)
        via_event = user.event_role_assignments.where(role: User::ADMIN_HELP_CHANNEL_ROLES).select(:event_id)
        via_series = Event.where(event_series_id: user.series_role_assignments.select(:event_series_id)).select(:id)

        Event.not_ended
          .where(id: via_event).or(Event.not_ended.where(id: via_series))
          .order(:starts_at)
      end

      def event_json(event)
        {
          id: event.id,
          name: event.name,
          slug: event.slug,
          starts_at: event.starts_at&.iso8601,
          ends_at: event.ends_at&.iso8601,
          dashboard_url: admin_event_dashboard_url(event.slug)
        }
      end
    end
  end
end
