class DashboardController < ApplicationController
  include TravelLegDateMerging
  include PhysicalDocumentUploads
  include OptionalDocumentEnrolment

  # MCP connections are managed from the profile page, so they follow the same
  # rule as the rest of it: admins without a participant record still get in.
  PROFILE_ACTIONS = %w[profile update_staff_profile destroy_staff_avatar
                       revoke_mcp_connection update_mcp_connection].freeze

  before_action :authenticate_user!
  before_action :require_participant, except: PROFILE_ACTIONS
  # Admins without a participant record still need the profile page — it's
  # where their staff settings (display name, avatar, contact info) live now.
  before_action :require_participant_or_admin, only: PROFILE_ACTIONS
  before_action :require_admin, only: [ :update_staff_profile, :destroy_staff_avatar, :update_mcp_connection ]

  def index
    # display_status per row walks travel/health/guardian/consent/custom-doc
    # associations, and the event avatars read logo attachments
    @participant_events = @participant.participant_events.includes(
      :consents, :travel_inbound, :travel_outbound, :accommodation,
      :medical, :dietary, :accessibility, :emergency_contacts,
      guardian_participant_events: :emergency_contacts,
      event: [ :custom_documents, { logo_attachment: :blob, event_series: { logo_attachment: :blob } } ]
    )
    @pending_invitations = @participant.pending_invitations.includes(
      event: [ { logo_attachment: :blob, event_series: { logo_attachment: :blob } } ]
    )
  end

  def profile
    if @participant
      @public_profile_events = @participant.public_profile_eligible_participant_events.preload(:event)
      # One [event, hidden] pair per staffed event — a user can hold several
      # roles on an event, and it's hidden only when every assignment is.
      @public_profile_staff_events = @participant.public_profile_eligible_staff_role_assignments
        .preload(:event)
        .group_by(&:event_id)
        .values
        .map { |assignments| [ assignments.first.event, assignments.all?(&:hidden_from_public_profile) ] }
        .sort_by { |event, _hidden| event.starts_at || Time.current }
        .reverse
    end
    # MCP is staff-only, so the Connections section is too — except for someone who
    # connected a client while they were staff and has since lost the role, who still
    # needs a way to clear the (now dead) connection out.
    @mcp_connections = mcp_connections
    @show_mcp_connections = current_user.admin? || @mcp_connections.any?
  end

  def update_staff_profile
    if current_user.update(staff_profile_params)
      redirect_to dashboard_profile_path(anchor: "staff-settings"), notice: "Staff settings updated."
    else
      redirect_to dashboard_profile_path(anchor: "staff-settings"),
        alert: current_user.errors.full_messages.to_sentence
    end
  end

  def destroy_staff_avatar
    current_user.avatar.purge_later
    redirect_to dashboard_profile_path(anchor: "staff-settings"), notice: "Profile picture removed."
  end

  # Tighten an MCP connection in place: narrow it to specific events, or turn on
  # anonymisation. Both directions of loosening are deliberately missing —
  # widening access means disconnecting the client and authorising it again, so
  # a wider grant always passes back through the consent screen.
  def update_mcp_connection
    application = Toolchest::OauthApplication.find_by(id: params[:id])
    return redirect_to(dashboard_profile_path(anchor: "connections"), alert: "Connection not found.") if application.nil?

    settings = McpConnectionSetting.find_or_create_by!(
      application_id: application.id, resource_owner_id: current_user.id.to_s
    )
    notices = []

    if params[:mcp_anonymize] == "1" && !settings.anonymize?
      settings.anonymize!(:dashboard)
      notices << "#{application.name} is now anonymised and read-only"
    end

    if params[:event_scope] == "selected"
      requested = mcp_scopable_events(settings).where(id: Array(params[:mcp_event_ids]).compact_blank).pluck(:id)
      if requested.empty?
        return redirect_to dashboard_profile_path(anchor: "connections"),
          alert: "Pick at least one event to limit #{application.name} to."
      end
      if settings.narrow_events!(requested)
        notices << "#{application.name} is now limited to #{settings.events.reload.order(:name).pluck(:name).to_sentence}"
      end
    end

    redirect_to dashboard_profile_path(anchor: "connections"),
      notice: notices.any? ? "#{notices.to_sentence}." : "Nothing changed."
  end

  # Disconnect an MCP client: revoke every live token and pending grant this
  # user holds for the application. The application row itself stays (it's a
  # global client registration, not per-user).
  def revoke_mcp_connection
    application = Toolchest::OauthApplication.find_by(id: params[:id])

    if application
      Toolchest::OauthAccessToken.revoke_all_for(application, current_user.id)
      Toolchest::OauthAccessGrant.revoke_all_for(application, current_user.id)
      redirect_to dashboard_profile_path(anchor: "connections"),
        notice: "#{application.name} has been disconnected."
    else
      redirect_to dashboard_profile_path(anchor: "connections"), alert: "Connection not found."
    end
  end

  def update_public_profile
    if @participant.update(public_profile_params)
      @participant.public_profile_photo.purge_later if params[:remove_public_profile_photo] == "1"
      update_public_profile_event_visibility
      update_public_profile_staff_event_visibility
      notice = @participant.public_profile_enabled? ? "Public profile updated." : "Public profile is off."
      redirect_to dashboard_profile_path, notice: notice
    else
      redirect_to dashboard_profile_path, alert: @participant.errors.full_messages.to_sentence
    end
  end

  def show
    @participant_event = @participant.participant_events
      .includes(:consents, :accommodation, :medical, :dietary, :accessibility,
                :emergency_contacts, :safeguarding_info,
                guardian_participant_events: :guardian,
                travel_inbound: :travel_legs, travel_outbound: :travel_legs,
                event: [ :custom_documents, { logo_attachment: :blob, event_series: { logo_attachment: :blob } } ])
      .find(params[:id])
    authorize @participant_event
    @event = @participant_event.event
    @scans = @participant_event.scans.includes(:user).recent.limit(20)
    @messages = @participant_event.message_deliveries
      .includes(message: :sent_by_user)
      .where(status: "delivered")
      .order(delivered_at: :desc)
      .limit(20)

    @custom_documents = @participant_event.applicable_custom_documents
    @optional_documents = @participant_event.relevant_optional_custom_documents
    # Documents live in the wizard while the participant is still filling it
    # in for the first time, and on the dashboard once they've submitted.
    # Adding an optional document reopens a completed participant, so
    # "in_progress" on its own no longer means "still in the wizard".
    @show_documents_section = @custom_documents.any? && !@participant_event.invited? &&
      (!@participant_event.in_progress? || @participant_event.onboarding_completed_at.present?)
    @custom_document_consents = @participant_event.consents
      .select(&:custom_document_id)
      .index_by(&:custom_document_id)

    waiver_consent = @participant_event.consents.find { |c| c.consent_type == "waiver" }
    if waiver_consent&.guardian_signed? && !waiver_consent&.participant_signed?
      set_current_event(@event)
      redirect_to onboarding_waiver_path, alert: "Please sign your waiver to complete your registration."
    end
  end

  def sign_document
    @participant_event = @participant.participant_events.includes(:event).find(params[:id])
    authorize @participant_event, :show?
    @event = @participant_event.event
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.applies_to?(@participant_event)
      redirect_to dashboard_event_path(@participant_event), alert: "This document doesn't apply to you."
      return
    end

    @consent = @participant_event.consents.find_or_create_by!(
      consent_type: :custom_document,
      custom_document: @custom_document
    )

    # Physical documents never touch DocuSeal — the page shows download +
    # photo-upload UI instead of an embedded signing form.
    if @custom_document.physical?
      @preparing = false
      return
    end

    if @consent.failed?
      @consent.update!(status: :pending, failure_reason: nil, docuseal_envelope_id: nil,
                       docuseal_participant_slug: nil, docuseal_guardian_slug: nil)
      DocusealJobs::CreateCustomDocumentJob.perform_later(@consent.id)
    elsif @consent.docuseal_envelope_id.blank? && !@consent.signed?
      # Duplicate enqueues are safe: the job no-ops once a submission exists.
      DocusealJobs::CreateCustomDocumentJob.perform_later(@consent.id)
    elsif !@consent.signed?
      # Catch signatures made in another tab or missed webhooks
      @consent.sync_from_docuseal!
    end

    @signing_url = @consent.participant_signing_url if @custom_document.participant_signs?
    @preparing = @consent.docuseal_envelope_id.blank? && @consent.requires_signature?
  end

  # Opting into an activity's waiver. Until this happens the document doesn't
  # exist for this participant — nobody, guardian included, is shown it.
  def add_optional_document
    @participant_event = @participant.participant_events.includes(:event, :consents).find(params[:id])
    authorize @participant_event, :update?
    @event = @participant_event.event
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.optional? && @custom_document.relevant_to?(@participant_event)
      redirect_to dashboard_event_path(@participant_event), alert: "That document isn't available to add."
      return
    end

    enrol_in_optional_document(@participant_event, @custom_document)

    if @custom_document.participant_signs?
      redirect_to dashboard_sign_document_path(@participant_event, @custom_document),
                  notice: "\"#{@custom_document.name}\" added."
    else
      redirect_to dashboard_event_path(@participant_event),
                  notice: "\"#{@custom_document.name}\" added — we've asked your parent/guardian to sign it."
    end
  end

  # Changing their mind. The consent is withdrawn rather than deleted, so a
  # signature already collected stays on file.
  def withdraw_optional_document
    @participant_event = @participant.participant_events.includes(:event, :consents).find(params[:id])
    authorize @participant_event, :update?
    @event = @participant_event.event
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.optional?
      redirect_to dashboard_event_path(@participant_event), alert: "That document can't be removed."
      return
    end

    if withdraw_from_optional_document(@participant_event, @custom_document).nil?
      redirect_to dashboard_event_path(@participant_event), alert: "You haven't added \"#{@custom_document.name}\"."
      return
    end

    redirect_to dashboard_event_path(@participant_event),
                notice: "\"#{@custom_document.name}\" removed. You can add it again any time."
  end

  def upload_physical_document
    @participant_event = @participant.participant_events.includes(:event).find(params[:id])
    authorize @participant_event, :show?
    @event = @participant_event.event
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.physical? && @custom_document.applies_to?(@participant_event) && @custom_document.participant_signs?
      redirect_to dashboard_event_path(@participant_event), alert: "This document doesn't apply to you."
      return
    end

    consent = @participant_event.consents.find_or_create_by!(
      consent_type: :custom_document,
      custom_document: @custom_document
    )

    if consent.signed?
      redirect_to dashboard_sign_document_path(@participant_event, @custom_document), notice: "This document is already confirmed."
      return
    end

    error = attach_physical_uploads(consent, params.dig(:consent, :physical_uploads))
    if error
      redirect_to dashboard_sign_document_path(@participant_event, @custom_document), alert: error
      return
    end

    consent.mark_physical_uploaded_by_participant!

    notice = if consent.signed?
      "\"#{@custom_document.name}\" uploaded — you're all set."
    else
      "\"#{@custom_document.name}\" uploaded. Your parent/guardian can now review and confirm it in their portal."
    end
    redirect_to dashboard_sign_document_path(@participant_event, @custom_document), notice: notice
  end

  # Uploads can be swapped out (blurry photo, wrong page) any time before the
  # document is confirmed.
  def remove_physical_upload
    @participant_event = @participant.participant_events.includes(:event).find(params[:id])
    authorize @participant_event, :show?
    @event = @participant_event.event
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.physical? && @custom_document.applies_to?(@participant_event) && @custom_document.participant_signs?
      redirect_to dashboard_event_path(@participant_event), alert: "This document doesn't apply to you."
      return
    end

    consent = @participant_event.consents.find_by(consent_type: :custom_document, custom_document: @custom_document)
    if consent.nil? || consent.signed?
      redirect_to dashboard_sign_document_path(@participant_event, @custom_document), alert: "This upload can no longer be removed."
      return
    end

    remove_physical_upload_attachment(consent, params[:upload_id])
    redirect_to dashboard_sign_document_path(@participant_event, @custom_document), notice: "Upload removed."
  end

  def resend_guardian_invite
    @participant_event = @participant.participant_events.find(params[:id])
    authorize @participant_event, :show?
    gpe = @participant_event.guardian_participant_events.first

    unless @participant_event.requires_guardian? && gpe
      redirect_to dashboard_event_path(@participant_event), alert: "No guardian on file for this event."
      return
    end

    if @participant_event.event.guardian_invites_locked?
      redirect_to dashboard_event_path(@participant_event), alert: "Guardian invitations aren't open for this event yet. We'll email your guardian as soon as they are."
      return
    end

    if gpe.invite_token_sent_at.present? && gpe.invite_token_sent_at > 2.minutes.ago
      redirect_to dashboard_event_path(@participant_event), alert: "An invitation was just sent — give it a couple of minutes to arrive."
      return
    end

    GuardianMailer.invitation(guardian_participant_event: gpe).deliver_later
    redirect_to dashboard_event_path(@participant_event), notice: "Invitation resent to #{gpe.guardian.email}."
  end

  def download_ticket
    @participant_event = @participant.participant_events
      .includes(:event, travel_inbound: :travel_legs, travel_outbound: :travel_legs)
      .find(params[:id])
    authorize @participant_event, :show?

    pdf = TicketPdfService.new(@participant_event).generate
    filename = "#{@participant_event.event.name.parameterize}-ticket.pdf"

    send_data pdf, filename: filename, type: "application/pdf", disposition: "attachment"
  end

  def download_excuse_letter
    @participant_event = @participant.participant_events.includes(:event).find(params[:id])
    authorize @participant_event, :show?

    pdf = SchoolExcuseLetterService.new(@participant_event).generate
    filename = "#{@participant_event.event.name.parameterize}-excuse-letter.pdf"

    send_data pdf, filename: filename, type: "application/pdf", disposition: "attachment"
  end

  def google_wallet
    @participant_event = @participant.participant_events.find(params[:id])
    authorize @participant_event, :show?

    # Debug: Check configuration
    Rails.logger.info("Google Wallet issuer_id: #{GoogleWallet.configuration&.issuer_id}")
    Rails.logger.info("Google Wallet credentials present: #{GoogleWallet.configuration&.json_credentials.present?}")

    url = ::GoogleWallet::EventTicket.new(@participant_event).save_url
    render json: { url: url }
  rescue StandardError => e
    Rails.logger.error("Google Wallet URL generation failed: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace&.first(10)&.join("\n"))
    render json: { error: "Failed to generate Google Wallet pass" }, status: :unprocessable_entity
  end

  def edit_travel
    @participant_event = @participant.participant_events
      .includes(travel_inbound: :travel_legs, travel_outbound: :travel_legs)
      .find(params[:id])
    authorize @participant_event, :update?
    @event = @participant_event.event
    return redirect_to dashboard_event_path(@participant_event) unless @event.travel_enabled?

    @travel_inbound = @participant_event.travel_inbound || @participant_event.build_travel_inbound(direction: :inbound)
    @travel_outbound = @participant_event.travel_outbound || @participant_event.build_travel_outbound(direction: :outbound)

    @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.plane? && @travel_inbound.travel_legs.empty?
    @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.plane? && @travel_outbound.travel_legs.empty?
  end

  def update_travel
    @participant_event = @participant.participant_events.find(params[:id])
    authorize @participant_event, :update?
    @event = @participant_event.event
    return redirect_to dashboard_event_path(@participant_event) unless @event.travel_enabled?

    @travel_inbound = @participant_event.travel_inbound || @participant_event.build_travel_inbound
    @travel_outbound = @participant_event.travel_outbound || @participant_event.build_travel_outbound

    Travel.transaction do
      inbound_saved = @travel_inbound.update(travel_params(:inbound))
      outbound_saved = @travel_outbound.update(travel_params(:outbound))

      if inbound_saved && outbound_saved
        redirect_to dashboard_event_path(@participant_event), notice: "Travel information updated successfully."
      else
        @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.plane? && @travel_inbound.travel_legs.reject(&:marked_for_destruction?).empty?
        @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.plane? && @travel_outbound.travel_legs.reject(&:marked_for_destruction?).empty?
        render :edit_travel, status: :unprocessable_entity
      end
    end
  end

  private

  def public_profile_params
    params.require(:participant).permit(
      :public_profile_enabled, :public_profile_slug, :public_profile_bio, :public_profile_show_photo,
      :public_profile_photo, :public_profile_location, :public_profile_website, :public_profile_github,
      :public_profile_twitter, :public_profile_linkedin, :public_profile_mastodon, :public_profile_bluesky
    )
  end

  # Checked boxes are the events shown on the profile; everything else in the
  # eligible set gets hidden. Scoped to the eligible set so stray ids can't
  # touch other rows.
  def update_public_profile_event_visibility
    eligible_ids = @participant.public_profile_eligible_participant_events.pluck(:id)
    return if eligible_ids.empty?

    visible_ids = Array(params[:visible_participant_event_ids]).compact_blank & eligible_ids

    @participant.participant_events.where(id: visible_ids)
      .update_all(hidden_from_public_profile: false)
    @participant.participant_events.where(id: eligible_ids - visible_ids)
      .update_all(hidden_from_public_profile: true)
  end

  # Same idea for staffed events, keyed by event id since a user can hold
  # several role assignments on one event. Scoped to the participant's own
  # eligible assignments so stray ids can't touch other rows.
  def update_public_profile_staff_event_visibility
    eligible_scope = @participant.public_profile_eligible_staff_role_assignments
    eligible_event_ids = eligible_scope.distinct.pluck(:event_id)
    return if eligible_event_ids.empty?

    visible_event_ids = Array(params[:visible_staff_event_ids]).compact_blank & eligible_event_ids

    eligible_scope.where(event_id: visible_event_ids)
      .update_all(hidden_from_public_profile: false)
    eligible_scope.where(event_id: eligible_event_ids - visible_event_ids)
      .update_all(hidden_from_public_profile: true)
  end

  # Live MCP connections for the signed-in user, one row per client
  # application. Mirrors toolchest's own authorized-applications semantics:
  # a connection counts as live while any token for the app is unrevoked
  # (access tokens expire in hours, but the client keeps refreshing them).
  def mcp_connections
    tokens = Toolchest::OauthAccessToken
      .where(resource_owner_id: current_user.id.to_s, revoked_at: nil)
      .includes(:application)

    settings = McpConnectionSetting.for_user(current_user).includes(:events).index_by(&:application_id)

    tokens.group_by(&:application).filter_map do |application, app_tokens|
      next unless application

      setting = settings[application.id]
      {
        application: application,
        scopes: app_tokens.flat_map(&:scopes_array).uniq.sort,
        connected_at: app_tokens.map(&:created_at).min,
        last_used_at: app_tokens.map(&:updated_at).max,
        settings: setting,
        anonymized: setting&.anonymize? || false,
        events: setting&.restricted_to_events? ? setting.events.sort_by { |e| e.name.to_s } : nil,
        scopable_events: mcp_scopable_events(setting)
      }
    end.sort_by { |connection| connection[:connected_at] }.reverse
  end

  # The events a connection could be narrowed to: what the user can reach, and
  # never wider than the connection already is.
  def mcp_scopable_events(setting)
    scope = current_user.global_admin? ? Event.all : current_user.assigned_events
    scope = scope.where(id: setting.permitted_event_ids) if setting&.restricted_to_events?
    scope.order(Arel.sql("starts_at DESC NULLS LAST"), :name)
  end

  def require_participant
    @participant = current_user.participant

    if @participant.nil?
      redirect_to onboarding_path, alert: "Please complete your profile first."
    end
  end

  def require_participant_or_admin
    @participant = current_user.participant

    if @participant.nil? && !current_user.admin?
      redirect_to onboarding_path, alert: "Please complete your profile first."
    end
  end

  def require_admin
    redirect_to dashboard_profile_path unless current_user.admin?
  end

  def staff_profile_params
    params.require(:user).permit(:display_name, :avatar, :phone_number, :slack_user_id)
  end

  def travel_params(direction)
    key = "travel_#{direction}"
    return { direction: direction } unless params[key].present?

    permitted = params.require(key).permit(
      :mode, :carrier, :flight_number, :departure_city, :departure_time,
      :arrival_city, :arrival_time, :arrival_location, :booking_reference,
      :visa_status, :visa_notes, :notes,
      :train_departure_station, :train_arrival_station,
      :bus_departure_location, :bus_arrival_location,
      :origin_address, :expected_arrival_time, :other_details,
      travel_legs_attributes: [ :id, :position, :flight_code, :departure_airport, :arrival_airport,
                               :departure_time, :departure_time_zone, :arrival_time, :arrival_time_zone, :confirmation_code, :_destroy ]
    ).merge(direction: direction)

    normalize_leg_times!(permitted)
    permitted
  end
end
