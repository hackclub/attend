module Api
  module V1
    # Global-admin only. Lets a support bot sitting in the admin help Slack
    # channel work out which events the person asking runs.
    class UsersController < BaseController
      requires_scope "support:read"
      before_action -> { require_global_admin!("Only global admins can look up users") }

      # Matches on the Slack ID Hack Club Auth vouches for, never the profile
      # override, and only among admin help channel members.
      def lookup
        slack_id = params[:slack_id].to_s.strip.upcase
        return render_error("slack_id is required") if slack_id.blank?

        # A Slack ID should belong to one account, but nothing enforces it.
        # Rather than answer for an arbitrary one, say so, like the
        # participants lookup does.
        matches = User.admin_help_channel_members.where(verified_slack_id: slack_id).limit(2).to_a
        if matches.size > 1
          return render json: { error: "More than one user matches that Slack ID" }, status: :conflict
        end

        user = matches.first
        return render json: { error: "Not found" }, status: :not_found unless user

        render json: {
          user: { id: user.id, name: user.name, email: user.email, global_admin: user.global_admin? },
          events: Event.admin_help_events_for(user).order(:starts_at).map { |event| event_json(event) }
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
          dashboard_url: AttendUrls.event_admin_url(event)
        }
      end
    end
  end
end
