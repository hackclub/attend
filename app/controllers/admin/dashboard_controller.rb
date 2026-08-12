class Admin::DashboardController < Admin::BaseController
  skip_before_action :set_current_event_from_session, only: [ :show, :integrations, :update_integrations, :trigger_airtable_sync, :create_vote_event ]

  def index
    # The picker's "All events" link deselects the current event.
    set_current_event(nil) if params[:deselect].present?

    @events = policy_scope(Event).includes(:event_series).order(starts_at: :desc)
    authorize Event, :index?
  end

  def show
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :show?

    set_current_event(@event)
    @events = Event.order(starts_at: :desc)

    load_dashboard_stats
    load_event_details
  end

  def integrations
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :show?

    set_current_event(@event)
    @events = Event.order(starts_at: :desc)
    load_airtable_sync_status
  end

  def trigger_airtable_sync
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :update?

    if @event.airtable_sync_configured?
      # "Sync Now" is a deliberate retry, so it also lifts a pause left by an
      # earlier failure — otherwise the scheduled job would skip this event and
      # the button would look like it did nothing.
      was_paused = @event.airtable_sync_paused?
      @event.resume_airtable_sync!
      AirtableJobs::SyncAllJob.perform_later

      notice = if was_paused
        "Airtable sync resumed and triggered. It will complete shortly."
      else
        "Airtable sync triggered. It will complete shortly."
      end
      redirect_to admin_event_integrations_path(@event), notice: notice
    else
      redirect_to admin_event_integrations_path(@event), alert: "Airtable sync is not fully configured."
    end
  end

  def create_vote_event
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :update?

    # Without a current event the audit row lands with a null event_id, which
    # hides it from every non-global admin's audit log.
    set_current_event(@event)

    client = Vote::Client.new

    if @event.vote_event_linked?
      redirect_to admin_event_integrations_path(@event),
        notice: "This event is already linked to a vote.hackclub.com event."
      return
    end

    unless client.configured?
      redirect_to admin_event_integrations_path(@event),
        alert: "The vote.hackclub.com API key is not configured on the server."
      return
    end

    # Backfill: if a vote event already exists for this slug, link it instead of
    # creating a duplicate.
    if (existing = client.find_event(@event.slug))
      @event.link_vote_event!(existing)
      redirect_to admin_event_integrations_path(@event),
        notice: "Linked to the existing vote.hackclub.com event for this slug."
      return
    end

    unless @event.logo.attached? && @event.banner.attached?
      redirect_to admin_event_integrations_path(@event),
        alert: "This event needs both a logo and a banner before a vote.hackclub.com event can be created."
      return
    end

    result = client.create_event(
      name: @event.name,
      slug: @event.slug,
      logo_url: public_attachment_url(@event.logo),
      background_url: public_attachment_url(@event.banner),
      admins: vote_admin_emails
    )
    @event.link_vote_event!(result)

    redirect_to admin_event_integrations_path(@event),
      notice: "Created vote.hackclub.com event."
  rescue Vote::Error => e
    # Lost a race (or slug taken): try to link the now-existing event.
    if e.status == 409 && (existing = client.find_event(@event.slug))
      @event.link_vote_event!(existing)
      redirect_to admin_event_integrations_path(@event),
        notice: "Linked to the existing vote.hackclub.com event for this slug."
    else
      redirect_to admin_event_integrations_path(@event),
        alert: "vote.hackclub.com: #{e.message.presence || 'Failed to create the vote event.'}"
    end
  end

  def update_integrations
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :update?

    set_current_event(@event)

    if @event.update(integration_params)
      if airtable_settings_saved?
        # Whoever last touched the credentials is who we email if the sync
        # later fails and pauses itself.
        @event.update_column(:airtable_config_updated_by_id, current_user.id)
        @event.resume_airtable_sync!
      end

      if airtable_settings_saved? && @event.airtable_sync_configured?
        AirtableJobs::SyncAllJob.perform_later
        redirect_to admin_event_integrations_path(@event), notice: "Integration settings updated. Airtable sync started."
      else
        redirect_to admin_event_integrations_path(@event), notice: "Integration settings updated."
      end
    else
      @events = Event.order(starts_at: :desc)
      load_airtable_sync_status
      render :integrations, status: :unprocessable_entity
    end
  end

  private

  AIRTABLE_SETTINGS = %i[
    airtable_api_key
    airtable_base_id
    airtable_sync_source_id
    airtable_sync_table_id
  ].freeze

  # New or corrected credentials should sync right away rather than sitting
  # broken-looking until the next scheduled run.
  def airtable_settings_saved?
    AIRTABLE_SETTINGS.any? { |setting| @event.public_send("saved_change_to_#{setting}?") }
  end

  # Emails granted event-admin access on the vote.hackclub.com event. Only
  # Attend event admins qualify — ops, safeguarding, and read-only roles don't
  # imply control over voting.
  def vote_admin_emails
    @event.event_role_assignments.event_admin.includes(:user).map { |a| a.user.email }
  end

  def public_attachment_url(attachment)
    Rails.application.routes.url_helpers.rails_storage_proxy_url(
      attachment,
      host: ENV.fetch("APP_HOST", "attend.hackclub.com"),
      protocol: "https"
    )
  end

  def load_airtable_sync_status
    @airtable_sync_configured = current_event.airtable_sync_configured?
    @airtable_synced_at = current_event.airtable_synced_at
    @airtable_sync_error = current_event.airtable_sync_error
    @airtable_sync_error_at = current_event.airtable_sync_error_at
    @airtable_sync_stale = current_event.airtable_sync_stale?
    @airtable_sync_paused = current_event.airtable_sync_paused?
    @airtable_sync_paused_at = current_event.airtable_sync_paused_at
    @airtable_config_owner = current_event.airtable_config_last_saved_by if @airtable_sync_paused
    @airtable_participant_count = current_event.participant_events.count if @airtable_sync_configured
  end

  def integration_params
    params.require(:event).permit(
      :docuseal_waiver_template_id,
      :docuseal_freedom_waiver_template_id,
      :slack_channel_id,
      :airtable_api_key,
      :airtable_base_id,
      :airtable_sync_source_id,
      :airtable_sync_table_id
    )
  end

  def load_dashboard_stats
    @participant_events = current_event.participant_events.includes(:participant, :safeguarding_info)

    @total_participants = @participant_events.count
    @status_counts = @participant_events.group(:status).count
    @display_status_counts = compute_display_status_counts
    @pending_invitations_count = current_event.invitations.pending.count

    # Travel stats
    @travel_stats = compute_travel_stats

    # Consent stats
    @consent_stats = compute_consent_stats

    # Incidents
    @open_incidents_count = current_event.incidents.open_incidents.count
    @recent_incidents = current_event.incidents
      .includes(participant_event: :participant, reported_by: [])
      .order(created_at: :desc)
      .limit(5)

    # High support participants
    @high_support_participants = @participant_events
      .joins(:safeguarding_info)
      .where(safeguarding_infos: { high_support_flag: true })
      .includes(:participant)

    # Recent activity
    @recent_activity = AuditLog
      .where(event: current_event)
      .includes(:actor)
      .order(created_at: :desc)
      .limit(8)

    # Event timeline info
    @event_status = compute_event_status

    # Staff count
    @staff_count = current_event.event_role_assignments.count
  end

  def compute_display_status_counts
    counts = Hash.new(0)
    @participant_events.includes(:consents, :event, :travel_inbound, :travel_outbound,
                                  :accommodation, :medical, :dietary, :accessibility, :safeguarding_info,
                                  :emergency_contacts, participant: [], guardian_participant_events: :emergency_contacts).find_each do |pe|
      counts[pe.display_status] += 1
    end
    counts
  end

  def compute_travel_stats
    pe_ids = current_event.participant_events.pluck(:id)

    inbound_travels = Travel.where(participant_event_id: pe_ids, direction: :inbound)
    outbound_travels = Travel.where(participant_event_id: pe_ids, direction: :outbound)

    {
      inbound_complete: inbound_travels.count,
      outbound_complete: outbound_travels.count,
      missing_inbound: @total_participants - inbound_travels.count,
      missing_outbound: @total_participants - outbound_travels.count,
      arriving_today: inbound_travels.joins(:travel_legs)
        .where("DATE(travel_legs.arrival_time) = ?", Date.current)
        .distinct.count,
      departing_today: outbound_travels.joins(:travel_legs)
        .where("DATE(travel_legs.departure_time) = ?", Date.current)
        .distinct.count
    }
  end

  def compute_consent_stats
    consents = Consent.joins(:participant_event)
      .where(participant_events: { event_id: current_event.id })

    {
      total: consents.count,
      signed: consents.signed.count,
      pending: consents.where(status: [ :pending, :sent, :viewed ]).count,
      waivers_signed: consents.where(consent_type: :waiver, status: :signed).count,
      waivers_pending: consents.where(consent_type: :waiver).where.not(status: :signed).count
    }
  end

  def compute_event_status
    now = Time.current
    event = current_event

    if event.starts_at.nil? || event.ends_at.nil?
      { phase: :draft, label: "Dates not set", color: "gray" }
    elsif now < event.starts_at
      days_until = (event.starts_at.to_date - Date.current).to_i
      if days_until <= 0
        { phase: :starting, label: "Starts today!", color: "green" }
      elsif days_until == 1
        { phase: :upcoming, label: "Starts tomorrow", color: "blue" }
      elsif days_until <= 7
        { phase: :upcoming, label: "#{days_until} days away", color: "blue" }
      else
        { phase: :planning, label: "#{days_until} days away", color: "gray" }
      end
    elsif now.between?(event.starts_at, event.ends_at)
      { phase: :active, label: "Event in progress", color: "green" }
    else
      { phase: :ended, label: "Event ended", color: "gray" }
    end
  end

  def load_event_details
    @event_role_assignments = current_event.event_role_assignments.includes(:user).order("users.email")
  end
end
