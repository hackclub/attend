class MeToolbox < ApplicationToolbox
  tool "Show the current authenticated user: their name, email, global role, and the events they can access.",
    access: :read, scope: %w[events:read participants:read] do
  end
  def show
    render json: {
      id: current_user.id,
      name: current_user.display_name_or_fallback,
      email: current_user.email,
      global_role: current_user.global_role,
      global_admin: current_user.global_admin?,
      events: current_user.event_role_assignments.includes(:event).map { |ra|
        { id: ra.event_id, name: ra.event.name, slug: ra.event.slug, role: ra.role,
          url: event_admin_url(ra.event) }
      },
      accessible_scopes: auth&.scopes,
      urls: {
        # Where a participant turns their own public profile on — the only way a
        # /p/:slug profile link ever comes into existence.
        profile_settings: attend_url("/dashboard/profile"),
        participant_dashboard: attend_url("/dashboard")
      }
    }
  end
end
