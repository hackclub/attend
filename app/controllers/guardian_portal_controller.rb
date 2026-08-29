class GuardianPortalController < ApplicationController
  include TravelLegDateMerging
  include PhysicalDocumentUploads

  skip_before_action :set_current_attributes

  before_action :load_guardian_context
  before_action :redirect_if_withdrawn, except: [ :withdrawn ]
  before_action :redirect_if_expired, except: [ :expired, :withdrawn ]
  before_action :redirect_if_completed, only: [ :show, :step, :update, :update_step ]
  before_action :mark_accepted_if_needed, only: [ :update, :update_step, :complete ]

  STEPS = %w[participant_info details emergency consents].freeze

  def show
    @steps = STEPS
    @completed_steps = completed_steps
    @docs_awaiting_participant_upload = docs_awaiting_participant_upload
  end

  def update
    if @guardian.update(guardian_params)
      redirect_to guardian_portal_path(token: @token), notice: "Your information has been updated."
    else
      @steps = STEPS
      @completed_steps = completed_steps
      @docs_awaiting_participant_upload = docs_awaiting_participant_upload
      render :show, status: :unprocessable_entity
    end
  end

  def step
    @step = params[:step]

    unless STEPS.include?(@step)
      redirect_to guardian_portal_path(token: @token), alert: "Invalid step."
      return
    end

    @step_index = STEPS.index(@step)
    load_wizard_position
    load_step_data
  end

  def update_step
    @step = params[:step]

    unless STEPS.include?(@step)
      redirect_to guardian_portal_path(token: @token), alert: "Invalid step."
      return
    end

    @step_index = STEPS.index(@step)

    if save_step_data
      if params[:advance] && next_step
        redirect_to guardian_portal_step_path(token: @token, step: next_step), notice: "Progress saved."
      else
        redirect_to guardian_portal_path(token: @token), notice: "Progress saved."
      end
    else
      # The step partials render bare forms, so a rejected save (a guardian
      # email or phone that matches the participant's, say) would otherwise
      # bounce back looking identical to a successful one.
      flash.now[:alert] = step_error_message
      load_wizard_position
      load_step_data
      render :step, status: :unprocessable_entity
    end
  end

  def complete
    unless all_guardian_steps_complete?
      redirect_to guardian_portal_path(token: @token), alert: "Please complete all required steps before submitting."
      return
    end

    # Completing the guardian fires GuardianParticipantEvent's after_update_commit
    # hook, which is what marks the participant complete once every guardian is
    # done — doing it here read a stale copy of this very row.
    @guardian_participant_event.update!(status: :completed, completed_at: Time.current)
    trigger_docuseal_if_needed

    redirect_to guardian_portal_confirmed_path(token: @token), notice: "Thank you! Your portion is complete."
  end

  def confirmed
  end

  def waiver
    if waivers_paused?
      @waiver_paused = true
      return
    end

    @consent = @participant_event.consents.waiver.first

    unless @consent&.docuseal_guardian_slug.present?
      render :waiver_loading
      return
    end

    @signing_url = Docuseal.signing_url(@consent.docuseal_guardian_slug, host: @consent.docuseal_host)
  end

  def waiver_complete
    redirect_to guardian_portal_step_path(token: @token, step: :consents), notice: "Thank you for signing the waiver!"
  end

  def freedom_waiver
    if waivers_paused?
      @waiver_paused = true
      return
    end

    @consent = @participant_event.consents.freedom_waiver.first

    unless @consent&.docuseal_guardian_slug.present?
      render :waiver_loading
      return
    end

    @signing_url = Docuseal.signing_url(@consent.docuseal_guardian_slug, host: @consent.docuseal_host)
  end

  def freedom_waiver_complete
    redirect_to guardian_portal_step_path(token: @token, step: :consents), notice: "Thank you for completing the Freedom Waiver!"
  end

  def custom_document
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.guardian_signs? && @custom_document.applies_to?(@participant_event)
      redirect_to guardian_portal_confirmed_path(token: @token), alert: "This document doesn't need your signature."
      return
    end

    @consent = @participant_event.consents.find_or_create_by!(
      consent_type: :custom_document,
      custom_document: @custom_document
    ) do |c|
      c.guardian_participant_event = @guardian_participant_event
    end

    # Physical documents: the guardian either uploads the signed form
    # themselves (guardian-only) or reviews the participant's uploaded photo
    # and confirms it — no DocuSeal involved.
    if @custom_document.physical?
      @awaiting_participant = @custom_document.participant_signs? && !@consent.physical_uploaded?
      return
    end

    if @consent.failed?
      @consent.update!(status: :pending, failure_reason: nil, docuseal_envelope_id: nil,
                       docuseal_participant_slug: nil, docuseal_guardian_slug: nil)
      DocusealJobs::CreateCustomDocumentJob.perform_later(@consent.id, "guardian")
    elsif @consent.docuseal_envelope_id.blank? && !@consent.signed?
      DocusealJobs::CreateCustomDocumentJob.perform_later(@consent.id, "guardian")
    end

    return if @consent.signed?

    # Submission created before this guardian existed (participant-only) —
    # there is no guardian slot on it, so don't spin on the loading screen.
    if @consent.docuseal_envelope_id.present? && @consent.docuseal_guardian_slug.blank?
      redirect_to guardian_portal_confirmed_path(token: @token),
                  notice: "#{@participant.legal_first_name} is handling this document."
      return
    end

    unless @consent.docuseal_guardian_slug.present?
      render :waiver_loading
      return
    end

    @awaiting_participant = @custom_document.participant_signs? && @custom_document.guardian_signs? && !@consent.participant_signed?
    @signing_url = Docuseal.signing_url(@consent.docuseal_guardian_slug, host: @consent.docuseal_host)
  end

  def custom_document_complete
    redirect_to guardian_portal_confirmed_path(token: @token), notice: "Thank you for signing!"
  end

  # The guardian reviewed the photo of the physically signed document and
  # ticked the box confirming it's accurate and complete.
  def verify_physical_document
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])
    consent = @participant_event.consents.find_by(consent_type: :custom_document, custom_document: @custom_document)

    unless @custom_document.physical? && consent&.physical_uploaded? && !consent.signed?
      redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id)
      return
    end

    unless params[:confirm_accurate] == "1"
      redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id),
                  alert: "Please tick the box to confirm the document is accurate and complete."
      return
    end

    consent.verify_physical_upload!(@guardian_participant_event)
    redirect_to after_guardian_document_path, notice: "Thank you for confirming #{@custom_document.name}!"
  end

  # Guardian-only physical documents: the guardian downloads, signs on paper,
  # and uploads the photo themselves — the upload completes the consent.
  def upload_physical_document
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.physical? && @custom_document.signed_by_guardian? && @custom_document.applies_to?(@participant_event)
      redirect_to guardian_portal_confirmed_path(token: @token), alert: "This document doesn't need your signature."
      return
    end

    consent = @participant_event.consents.find_or_create_by!(
      consent_type: :custom_document,
      custom_document: @custom_document
    ) do |c|
      c.guardian_participant_event = @guardian_participant_event
    end

    if consent.signed?
      redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id),
                  notice: "This document is already confirmed."
      return
    end

    error = attach_physical_uploads(consent, params.dig(:consent, :physical_uploads))
    if error
      redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id), alert: error
      return
    end

    consent.mark_physical_uploaded_by_guardian!(@guardian_participant_event)
    redirect_to after_guardian_document_path, notice: "\"#{@custom_document.name}\" uploaded — thank you!"
  end

  # Guardians can swap out their own uploads (blurry photo, wrong page) any
  # time before the document is confirmed.
  def remove_physical_upload
    @custom_document = @event.custom_documents.active.find(params[:custom_document_id])

    unless @custom_document.physical? && @custom_document.signed_by_guardian? && @custom_document.applies_to?(@participant_event)
      redirect_to guardian_portal_confirmed_path(token: @token), alert: "This document doesn't need your signature."
      return
    end

    consent = @participant_event.consents.find_by(consent_type: :custom_document, custom_document: @custom_document)
    if consent.nil? || consent.signed?
      redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id),
                  alert: "This upload can no longer be removed."
      return
    end

    remove_physical_upload_attachment(consent, params[:upload_id])
    redirect_to guardian_portal_custom_document_path(token: @token, custom_document_id: @custom_document.id),
                notice: "Upload removed."
  end

  def expired
  end

  def withdrawn
  end

  private

  # After acting on a physical document, guardians mid-portal go back to the
  # consents step; guardians who already completed go to the confirmed page.
  def after_guardian_document_path
    if @guardian_participant_event.completed?
      guardian_portal_confirmed_path(token: @token)
    else
      guardian_portal_step_path(token: @token, step: "consents")
    end
  end

  def waivers_paused?
    Setting.waiver_sending_paused? || @event.guardian_invites_locked?
  end

  def load_guardian_context
    @token = params[:token]

    unless @token.present?
      render :error, status: :not_found and return
    end

    begin
      @guardian_participant_event = GuardianParticipantEvent.find_by_invite_token!(@token)
    rescue ActiveRecord::RecordNotFound
      render :error, status: :not_found and return
    end

    # Keeps the invite alive while the guardian is actually working through the
    # portal, so a long gathering-documents stretch does not expire mid-flow.
    @guardian_participant_event.touch_invite_use!

    @guardian = @guardian_participant_event.guardian
    @participant_event = @guardian_participant_event.participant_event
    @participant = @participant_event.participant
    @event = @participant_event.event
  end

  def mark_accepted_if_needed
    return if @guardian_participant_event.accepted_at.present?

    @guardian_participant_event.mark_accepted!
  end

  def redirect_if_withdrawn
    return unless @participant_event.withdrawn?

    redirect_to guardian_portal_withdrawn_path(token: @token)
  end

  def redirect_if_expired
    return unless @guardian_participant_event.invite_expired?

    redirect_to guardian_portal_expired_path(token: @token)
  end

  def redirect_if_completed
    return unless @guardian_participant_event.completed?

    redirect_to guardian_portal_confirmed_path(token: @token)
  end

  def step_params(step_name)
    case step_name
    when "participant_info"
      {
        participant: params.fetch(:participant, {}).permit(
          :legal_first_name, :legal_last_name, :date_of_birth,
          :email, :phone, :pronouns, :address_line_1, :address_line_2,
          :city, :state, :postal_code, :country_of_residence, :tshirt_size
        ),
        medical: params.fetch(:medical, {}).permit(
          :allergies, :medical_conditions, :medications, :has_anaphylaxis_risk, :requires_refrigeration
        ),
        dietary: params.fetch(:dietary, {}).permit(
          :diet_type, :intolerances, :life_threatening_allergies
        ),
        accessibility: params.fetch(:accessibility, {}).permit(
          :has_adhd, :has_dyslexia, :has_autism, :neurodivergent_notes,
          :uses_wheelchair, :step_free_required, :needs_large_print,
          :needs_captioning, :needs_sign_language, :other_needs
        ),
        travel_inbound: params.fetch(:travel_inbound, {}).permit(
          :mode, :is_unaccompanied_minor,
          :train_departure_station, :train_arrival_station,
          :bus_departure_location, :bus_arrival_location,
          :origin_address, :expected_arrival_time, :other_details,
          :departure_time, :arrival_time,
          travel_legs_attributes: [ :id, :position, :flight_code, :departure_airport, :arrival_airport,
                                   :departure_time, :departure_time_zone, :arrival_time, :arrival_time_zone, :confirmation_code, :_destroy ]
        ),
        travel_outbound: params.fetch(:travel_outbound, {}).permit(
          :mode, :is_unaccompanied_minor,
          :train_departure_station, :train_arrival_station,
          :bus_departure_location, :bus_arrival_location,
          :origin_address, :expected_arrival_time, :other_details,
          :departure_time, :arrival_time,
          travel_legs_attributes: [ :id, :position, :flight_code, :departure_airport, :arrival_airport,
                                   :departure_time, :departure_time_zone, :arrival_time, :arrival_time_zone, :confirmation_code, :_destroy ]
        )
      }
    when "details"
      params.require(:guardian).permit(
        :legal_first_name, :legal_last_name, :email, :phone,
        :address_line_1, :address_line_2, :city, :state, :postal_code, :country
      )
    when "emergency"
      params.require(:guardian_participant_event).permit(
        :emergency_medical_consent,
        :otc_medication_consent,
        emergency_contacts_attributes: [
          :id,
          :name,
          :relationship,
          :phone,
          :email,
          :priority,
          :_destroy
        ]
      )
    when "consents"
      params.require(:consent).permit(:consent_type, :agreed, :signature)
    else
      {}
    end
  end

  def guardian_params
    params.require(:guardian).permit(
      :legal_first_name, :legal_last_name, :email, :phone,
      :address_line_1, :address_line_2,
      :city, :state, :postal_code, :country
    )
  end

  def all_guardian_steps_complete?
    @guardian.legal_first_name.present? &&
      @guardian.legal_last_name.present? &&
      @guardian.email.present? &&
      @guardian.phone.present? &&
      @guardian_participant_event.emergency_contacts.any? &&
      consents_complete?
  end

  def details_complete?
    @guardian.legal_first_name.present? &&
      @guardian.legal_last_name.present? &&
      @guardian.email.present? &&
      @guardian.phone.present? &&
      @guardian_participant_event.relationship.present? &&
      @guardian.address_line_1.present? &&
      @guardian.city.present? &&
      @guardian.state.present? &&
      @guardian.postal_code.present? &&
      @guardian.country.present?
  end

  def consents_complete?
    pending_consent_types.empty?
  end

  def pending_consent_types
    pending = []

    # Check waiver (requires guardian signature)
    waiver_consent = @participant_event.consents.find_by(consent_type: "waiver")
    pending << "waiver" unless waiver_consent&.guardian_signed?

    # Check freedom waiver (requires full signature since parent-only) - only if enabled
    if @event.freedom_waivers_enabled?
      freedom_consent = @participant_event.consents.find_by(consent_type: "freedom_waiver")
      pending << "freedom_waiver" unless freedom_consent&.signed?
    end

    # Physical custom documents the guardian can act on right now block
    # completion: guardian-only ones they must sign & upload themselves, and
    # participant uploads awaiting their review. (Dual-signer documents the
    # participant hasn't uploaded yet don't block — there's nothing to review.)
    @participant_event.applicable_custom_documents.select(&:physical?).select(&:guardian_signs?).each do |doc|
      consent = @participant_event.consents.find_by(consent_type: "custom_document", custom_document: doc)
      next if consent&.signed?

      if doc.signed_by_guardian? || consent&.physical_uploaded?
        pending << "custom_document_#{doc.id}"
      end
    end

    pending
  end

  def completed_steps
    completed = []
    completed << "participant_info" if participant_info_complete?
    completed << "details" if details_complete?
    completed << "emergency" if @guardian_participant_event.emergency_contacts.any?
    completed << "consents" if consents_complete?
    completed
  end

  # Dual-signer physical documents the participant hasn't uploaded yet. These
  # don't block the guardian's submission (see pending_consent_types), but the
  # guardian will be asked to confirm them later — the overview must say so
  # instead of claiming everything is done.
  def docs_awaiting_participant_upload
    @participant_event.applicable_custom_documents.select do |doc|
      next false unless doc.physical? && doc.participant_signs? && doc.guardian_signs?

      consent = @participant_event.consents.find_by(consent_type: "custom_document", custom_document: doc)
      !consent&.signed? && !consent&.physical_uploaded?
    end
  end

  def participant_info_complete?
    @guardian_participant_event.participant_info_reviewed_at.present?
  end

  # Data the wizard's position indicator needs on every step render.
  def load_wizard_position
    @steps = STEPS
    @current_step = @step
    @completed_steps = completed_steps
  end

  def load_step_data
    case @step
    when "participant_info"
      @participant_data = @participant
      @medical = @participant_event.medical || @participant_event.build_medical
      @dietary = @participant_event.dietary || @participant_event.build_dietary
      @accessibility = @participant_event.accessibility || @participant_event.build_accessibility
      @travel_inbound = @participant_event.travel_inbound || @participant_event.travels.build(direction: "inbound")
      @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.travel_legs.empty?
      @travel_outbound = @participant_event.travel_outbound || @participant_event.travels.build(direction: "outbound")
      @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.travel_legs.empty?
    when "details"
      @guardian_data = @guardian
    when "emergency"
      ensure_guardian_emergency_contact_exists
      @emergency_contacts = @guardian_participant_event.emergency_contacts.by_priority.reload
      @emergency_contact ||= if params[:contact_id].present?
        @guardian_participant_event.emergency_contacts.find_by(id: params[:contact_id])
      end
      @emergency_contact ||= @guardian_participant_event.emergency_contacts.build(priority: next_priority(@emergency_contacts))
    when "consents"
      @waivers_paused = waivers_paused?
      ensure_waiver_exists_and_triggered
      consent_types = Consent::REQUIRED_CONSENT_TYPES.dup
      consent_types -= [ "freedom_waiver" ] unless @event.freedom_waivers_enabled?
      @consents = @participant_event.consents.where(consent_type: consent_types)
      @required_consent_types = consent_types
    end
  end

  def step_error_message
    messages = [ @guardian, @participant ].compact.flat_map { |record| record.errors.full_messages }
    return "We couldn't save your changes. Please check the highlighted fields and try again." if messages.empty?

    messages.uniq.to_sentence
  end

  def save_step_data
    case @step
    when "participant_info"
      save_participant_info_data
    when "details"
      details = step_params("details")
      if details[:phone].present? && @participant.phone.present?
        guardian_phone_parsed = Phonelib.parse(details[:phone])
        if guardian_phone_parsed.valid? && guardian_phone_parsed.e164 == @participant.phone
          @guardian.errors.add(:phone, "cannot be the same as the participant's phone number")
          return false
        end
      end
      guardian_saved = @guardian.update(details)
      relationship_saved = params[:relationship].present? ? @guardian_participant_event.update(relationship: params[:relationship]) : true
      guardian_saved && relationship_saved
    when "emergency"
      save_emergency_contact_data
    when "consents"
      consent_params = step_params("consents")
      consent = @guardian_participant_event.consents.find_or_initialize_by(consent_type: consent_params[:consent_type])
      consent.update(consent_params)
    else
      true
    end
  end

  def save_participant_info_data
    all_params = step_params("participant_info")

    participant_saved = @participant.update(all_params[:participant])

    medical = @participant_event.medical || @participant_event.build_medical
    medical_saved = medical.update(all_params[:medical])

    dietary = @participant_event.dietary || @participant_event.build_dietary
    dietary_params = all_params[:dietary]
    dietary_params[:diet_type] = nil if dietary_params[:diet_type].blank?
    dietary_saved = dietary.update(dietary_params)

    accessibility = @participant_event.accessibility || @participant_event.build_accessibility
    accessibility_saved = accessibility.update(all_params[:accessibility])

    # Save travel data
    inbound_saved = outbound_saved = true
    if @event.travel_enabled?
      inbound_params = all_params[:travel_inbound] || {}
      outbound_params = all_params[:travel_outbound] || {}

      # Skip saving empty legs when not plane mode
      inbound_params.delete(:travel_legs_attributes) if inbound_params[:mode] != "plane"
      outbound_params.delete(:travel_legs_attributes) if outbound_params[:mode] != "plane"

      # UM is the airline's paid chaperone service, not just "under 18 flying
      # alone" — the adult must explicitly confirm the booking is real.
      um_declared = um_declared_in?(inbound_params) || um_declared_in?(outbound_params)
      if um_declared && params[:um_guardian_confirmation] != "1"
        flash.now[:alert] = "Please confirm that your child is formally booked with the airline's unaccompanied minor service (or untick the unaccompanied minor option if they are not)."
        return false
      end

      # Convert manual wall-clock leg times to UTC using their picked/airport timezone
      normalize_leg_times!(inbound_params)
      normalize_leg_times!(outbound_params)

      inbound = @participant_event.travel_inbound || @participant_event.travels.build(direction: "inbound")
      inbound.assign_attributes(inbound_params)
      inbound_saved = inbound.save

      outbound = @participant_event.travel_outbound || @participant_event.travels.build(direction: "outbound")
      outbound.assign_attributes(outbound_params)
      outbound_saved = outbound.save

      @participant_event.update(um_guardian_confirmed_at: um_declared ? (@participant_event.um_guardian_confirmed_at || Time.current) : nil)
      # reload: the travel has_one associations were cached before the travels
      # above were created, and request_um_review! re-derives the declaration.
      @participant_event.reload.request_um_review! if um_declared
    end

    @guardian_participant_event.update(participant_info_reviewed_at: Time.current)

    participant_saved && medical_saved && dietary_saved && accessibility_saved && inbound_saved && outbound_saved
  end

  def um_declared_in?(travel_params)
    travel_params[:mode] == "plane" &&
      ActiveRecord::Type::Boolean.new.cast(travel_params[:is_unaccompanied_minor])
  end

  def save_emergency_contact_data
    contact_params = params.require(:emergency_contact).permit(:id, :name, :relationship, :phone, :email, :priority)

    @emergency_contact = if contact_params[:id].present?
      @guardian_participant_event.emergency_contacts.find_by(id: contact_params[:id])
    end
    @emergency_contact ||= @guardian_participant_event.emergency_contacts.build

    @emergency_contact.assign_attributes(contact_params.except(:id))
    @emergency_contact.save
  end

  def next_step
    current_index = STEPS.index(@step)
    STEPS[current_index + 1] if current_index && current_index < STEPS.length - 1
  end

  def trigger_docuseal_if_needed
    ensure_waiver_exists_and_triggered
    ensure_guardian_custom_documents_triggered
  end

  # Guardian-only custom documents are the guardian's to sign — create their
  # submissions as soon as the portal is completed (DocuSeal emails the link)
  # instead of waiting for anyone to open a signing page.
  def ensure_guardian_custom_documents_triggered
    @participant_event.applicable_custom_documents.select(&:signed_by_guardian?).each do |doc|
      consent = @participant_event.consents.find_or_create_by!(consent_type: :custom_document, custom_document: doc) do |c|
        c.guardian_participant_event = @guardian_participant_event
      end

      # Physical documents are signed on paper — nothing to send.
      next if doc.physical?

      if consent.docuseal_envelope_id.blank? && !consent.signed? && !consent.failed?
        DocusealJobs::CreateCustomDocumentJob.perform_later(consent.id)
      end
    end
  end

  def ensure_waiver_exists_and_triggered
    # While guardian invites are locked (or waiver sending is globally paused),
    # don't create consents or DocuSeal submissions — participant_events without
    # waiver consents are what SendPendingGuardianInvitesJob backfills on unlock.
    return if waivers_paused?

    # Create and trigger the main waiver
    waiver = @participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
      c.status = :pending
      c.guardian_participant_event = @guardian_participant_event
    end

    unless waiver.signed? || waiver.sent?
      DocusealJobs::CreateMinorWaiverJob.perform_later(waiver.id)
    end

    if waiver.failed?
      waiver.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateMinorWaiverJob.perform_later(waiver.id)
    end

    # Create and trigger the freedom waiver (only if enabled for this event)
    return unless @event.freedom_waivers_enabled?

    freedom_waiver = @participant_event.consents.find_or_create_by!(consent_type: :freedom_waiver) do |c|
      c.status = :pending
      c.guardian_participant_event = @guardian_participant_event
    end

    unless freedom_waiver.signed? || freedom_waiver.sent?
      DocusealJobs::CreateFreedomWaiverJob.perform_later(freedom_waiver.id)
    end

    if freedom_waiver.failed?
      freedom_waiver.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateFreedomWaiverJob.perform_later(freedom_waiver.id)
    end
  end

  def next_priority(contacts)
    max_priority = contacts.map(&:priority).compact.max || 0
    [ max_priority + 1, 3 ].min
  end

  def ensure_guardian_emergency_contact_exists
    return if @guardian_participant_event.emergency_contacts.exists?
    return unless @guardian.phone.present?

    @guardian_participant_event.emergency_contacts.create!(
      name: @guardian.full_name,
      phone: @guardian.phone,
      email: @guardian.email,
      relationship: @guardian_participant_event.relationship.presence || "Parent/Guardian",
      priority: 1
    )
  end
end
