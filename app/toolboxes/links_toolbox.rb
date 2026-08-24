class LinksToolbox < ApplicationToolbox
  # Agents kept handing people bare IDs ("her participant id is 808db791-…")
  # because nothing told them what an Attend URL looks like. Most read tools now
  # return a `url` on every record; this toolbox covers the rest — the page
  # patterns, and every link that exists for one person.
  #
  # Templates are checked against the real route helpers in
  # spec/toolboxes/links_toolbox_spec.rb, so they can't quietly rot.

  PATTERNS = {
    "public participant profile" => {
      template: "/p/{public_profile_slug}",
      notes: "Opt-in only. Participants enable it themselves at /dashboard/profile. " \
             "If public_profile_url is null there is no profile link — say so instead of guessing a slug."
    },
    "event admin dashboard" => {
      template: "/admin/{event_slug}",
      notes: "The staff home for an event. Note the short form: no /events/ segment here."
    },
    "event participant list" => {
      template: "/admin/events/{event_slug}/participants",
      notes: "Supports ?search=, ?status= and ?flag= query params, same as the UI filters."
    },
    "one participant at one event" => {
      template: "/admin/events/{event_slug}/participants/{participant_event_id}",
      notes: "Keyed by participant_event_id (one registration), NOT participant_id. " \
             "A person registered for three events has three of these pages."
    },
    "participant sub-pages" => {
      template: "/admin/events/{event_slug}/participants/{participant_event_id}/{page}",
      notes: "page is one of: #{AttendUrls::PARTICIPANT_PAGES.join(", ")}. " \
             "medical and safeguarding need the matching event role."
    },
    "event incident" => {
      template: "/admin/events/{event_slug}/incidents/{incident_id}",
      notes: "List at /admin/events/{event_slug}/incidents."
    },
    "event message/blast" => {
      template: "/admin/events/{event_slug}/messages/{message_id}",
      notes: "List at /admin/events/{event_slug}/messages."
    },
    "event groups" => { template: "/admin/events/{event_slug}/groups", notes: nil },
    "rooming wizard" => { template: "/admin/events/{event_slug}/rooming_wizard", notes: nil },
    "check-in scanner" => { template: "/admin/events/{event_slug}/scans/scanner", notes: nil },
    "airport mode" => { template: "/admin/events/{event_slug}/airport_mode", notes: nil },
    "support ticket" => { template: "/support/tickets/{ticket_id}", notes: "Not event-scoped." },
    "participant's own dashboard" => {
      template: "/dashboard",
      notes: "Renders for whoever is signed in. There is no way to link a staff user at " \
             "another person's dashboard — link their admin participant page instead."
    },
    "guardian portal finder" => {
      template: "/guardian/portals",
      notes: "Where a guardian recovers their own portal links. Individual portal URLs contain " \
             "a secret token and are never safe to construct or share."
    }
  }.freeze

  tool "The URL patterns for Attend pages — use this when you need to link somewhere no other tool " \
       "returned a url for. Read tools already include a `url` on the records they return; prefer those.",
    access: :read, scope: %w[events:read participants:read] do
  end
  def patterns
    render json: {
      base_url: attend_base_url,
      how_to_use: "Join base_url with a template and substitute the {placeholders}. " \
                  "IDs are UUIDs; event_slug is the event's slug, not its name or ID.",
      pages: PATTERNS.map { |name, pattern|
        { page: name, url_template: "#{attend_base_url}#{pattern[:template]}", notes: pattern[:notes] }.compact
      },
      cautions: [
        "Never invent a link for a page you haven't confirmed exists — say you don't have one.",
        "Token URLs (guardian invites/portals, wallet passes, NFC badges) are secrets. Don't construct or forward them.",
        "A participant_id alone can't be linked anywhere. Use links_participant to turn one into real URLs."
      ]
    }
  end

  tool "Every link that exists for one participant: their public profile if they have one, " \
       "and their admin page (plus sub-pages) for each event you can access.",
    access: :read, scope: "participants:read" do
    param :participant_id, :string, "Participant ID"
    param :event_id, :string, "Only link this event", optional: true
    param :event_slug, :string, "Only link this event by slug", optional: true
  end
  def participant
    @participant = Participant.find(params[:participant_id])

    registrations = @participant.participant_events.includes(:event)
    unless current_user.global_admin?
      registrations = registrations.where(event_id: current_user.assigned_events.select(:id))
    end
    if (event = current_event)
      registrations = registrations.where(event_id: event.id)
    end
    registrations = registrations.to_a
    halt error: "You don't have access to any event this participant is registered for." if registrations.empty?

    profile_url = public_profile_url(@participant)
    render json: {
      participant_id: @participant.id,
      name: [ @participant.preferred_name.presence || @participant.legal_first_name,
              @participant.legal_last_name ].join(" "),
      public_profile_url: profile_url,
      public_profile_note: profile_url ? nil : "No public profile. Profiles are opt-in — only the " \
        "participant can enable one, at #{attend_url("/dashboard/profile")}. There is no profile link to share.",
      registrations: registrations.map { |pe|
        {
          participant_event_id: pe.id,
          event: pe.event.name,
          event_slug: pe.event.slug,
          status: pe.status,
          url: registration_url(pe),
          pages: AttendUrls::PARTICIPANT_PAGES.to_h { |page| [ page, registration_url(pe, page: page) ] }
        }
      }
    }
  end
end
