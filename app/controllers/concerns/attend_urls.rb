# Canonical absolute URLs for Attend pages, built from the routes rather than
# glued together by hand.
#
# The MCP toolboxes lean on this: every serialized record carries the URL of the
# page it lives on, so an agent can hand a human a link instead of an opaque ID
# (or worse, inventing a path that 404s). LinksToolbox publishes the same
# patterns for the pages nothing serializes yet.
module AttendUrls
  extend self

  # Sub-pages of one registration in the admin UI, keyed by the name a human
  # would use for them. These are all member routes on admin/participants.
  PARTICIPANT_PAGES = %w[edit travel accommodation medical safeguarding consents notes history merge].freeze

  # APP_HOST wins where it is set (production, staging, and a dev tunnel), and
  # it always carries its own port; the mailer options are the local fallback,
  # where the port lives separately.
  def attend_base_url
    options = Rails.application.config.action_mailer.default_url_options || {}
    env_host = ENV["APP_HOST"].presence
    host = env_host || options[:host].presence || "attend.hackclub.com"
    host = "#{host}:#{options[:port]}" if env_host.nil? && options[:port].present? && !host.include?(":")
    scheme = host.start_with?("localhost", "127.0.0.1") ? "http" : "https"
    "#{scheme}://#{host}"
  end

  def attend_url(path) = "#{attend_base_url}#{path}"

  def event_admin_url(event) = attend_url(routes.admin_event_dashboard_path(slug: event.slug))

  def event_participants_url(event) = attend_url(routes.admin_event_participants_path(event_slug: event.slug))

  def event_incidents_url(event) = attend_url(routes.admin_event_incidents_path(event_slug: event.slug))

  def event_messages_url(event) = attend_url(routes.admin_event_messages_path(event_slug: event.slug))

  def event_groups_url(event) = attend_url(routes.admin_event_groups_path(event_slug: event.slug))

  def event_rooming_url(event) = attend_url(routes.admin_event_rooming_wizard_path(event_slug: event.slug))

  def event_scanner_url(event) = attend_url(routes.scanner_admin_event_scans_path(event_slug: event.slug))

  def event_airport_mode_url(event) = attend_url(routes.admin_event_airport_mode_path(event_slug: event.slug))

  # The admin participant page is keyed by participant_event id, not participant
  # id — a person has one page per event they're registered for.
  def registration_url(participant_event, page: nil)
    slug = participant_event.event.slug
    id = participant_event.id
    return attend_url(routes.admin_event_participant_path(event_slug: slug, id: id)) if page.blank?

    page = page.to_s
    raise ArgumentError, "Unknown participant page #{page}" unless PARTICIPANT_PAGES.include?(page)

    attend_url(routes.public_send("#{page}_admin_event_participant_path", event_slug: slug, id: id))
  end

  def incident_admin_url(incident)
    attend_url(routes.admin_event_incident_path(event_slug: incident.event.slug, id: incident.id))
  end

  def message_admin_url(message)
    attend_url(routes.admin_event_message_path(event_slug: message.event.slug, id: message.id))
  end

  def ticket_url(ticket) = attend_url(routes.support_ticket_path(ticket))

  # Opt-in only: a participant with no public profile has no shareable profile
  # URL at all, and callers should say so rather than guessing a slug.
  def public_profile_url(participant)
    return nil unless participant.public_profile_enabled? && participant.public_profile_slug.present?

    attend_url(routes.public_profile_path(slug: participant.public_profile_slug))
  end

  private

  def routes = Rails.application.routes.url_helpers
end
