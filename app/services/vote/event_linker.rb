module Vote
  # Creates (or adopts) the vote.hackclub.com event for one Attend event, and
  # records the linkage.
  #
  # Two pages drive this — an event's own integrations page and its series'
  # integrations page — and the order of the checks is the whole substance of
  # it, so it lives here rather than in either controller: already linked, then
  # server configured, then adopt an existing event with this slug, then insist
  # on artwork, then create. Losing the create race means adopting instead.
  class EventLinker
    Result = Struct.new(:status, :message, keyword_init: true) do
      # Everything the caller shows as a notice rather than an alert: the event
      # is linked afterwards, whether this call is what linked it.
      def linked?
        %i[created linked_existing already_linked].include?(status)
      end
    end

    def initialize(event, client: nil)
      @event = event
      @client = client || Vote::Client.new
    end

    def call
      if @event.vote_event_linked?
        return result(:already_linked, "This event is already linked to a vote.hackclub.com event.")
      end

      unless @client.configured?
        return result(:not_configured, "The vote.hackclub.com API key is not configured on the server.")
      end

      # Backfill: if a vote event already exists for this slug, link it instead
      # of creating a duplicate.
      if (existing = @client.find_event(@event.slug))
        return adopt(existing)
      end

      unless artwork_ready?
        return result(
          :missing_artwork,
          "This event needs both a logo and a banner before a vote.hackclub.com event can be created."
        )
      end

      @event.link_vote_event!(
        @client.create_event(
          name: @event.name,
          slug: @event.slug,
          logo_url: public_attachment_url(@event.logo),
          background_url: public_attachment_url(@event.banner),
          admins: admin_emails
        )
      )
      result(:created, "Created vote.hackclub.com event.")
    rescue Vote::Error => e
      # Lost a race (or slug taken): try to link the now-existing event.
      if e.status == 409 && (existing = @client.find_event(@event.slug))
        adopt(existing)
      else
        result(:failed, "vote.hackclub.com: #{e.message.presence || 'Failed to create the vote event.'}")
      end
    end

    # Both pages disable the button without artwork, and say why.
    def artwork_ready?
      @event.logo.attached? && @event.banner.attached?
    end

    private

    def adopt(existing)
      @event.link_vote_event!(existing)
      result(:linked_existing, "Linked to the existing vote.hackclub.com event for this slug.")
    end

    # Emails granted event-admin access on the vote.hackclub.com event. Only
    # Attend event admins qualify — ops, safeguarding, and read-only roles
    # don't imply control over voting.
    def admin_emails
      @event.event_role_assignments.event_admin.includes(:user).map { |a| a.user.email }
    end

    # vote.hackclub.com fetches these images itself, so they have to be public
    # and absolute against the deployed host — not the host of this request.
    def public_attachment_url(attachment)
      Rails.application.routes.url_helpers.rails_storage_proxy_url(
        attachment,
        host: ENV.fetch("APP_HOST", "attend.hackclub.com"),
        protocol: "https"
      )
    end

    def result(status, message)
      Result.new(status: status, message: message)
    end
  end
end
