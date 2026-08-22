class OnboardingController < ApplicationController
  include TravelLegDateMerging
  include PhysicalDocumentUploads
  include OptionalDocumentEnrolment

  before_action :force_html_format, except: [ :documents_status ]
  before_action :store_invitation_token
  before_action :authenticate_user!
  before_action :process_invitation
  before_action :load_participant_event
  before_action :redirect_if_withdrawn
  before_action :redirect_if_locked, except: [ :index, :waiver, :waiver_complete ]

  BASE_STEPS = %w[profile travel accommodation health].freeze
  GUARDIAN_STEP = "guardian"
  EMERGENCY_STEP = "emergency"
  WAIVER_STEP = "waiver"
  DOCUMENTS_STEP = "documents"
  REVIEW_STEP = "review"

  def index
    # If all regular onboarding steps are done and participant still needs to sign
    # their portion of the waiver, send them directly to the waiver page (which is
    # exempt from redirect_if_locked) instead of back into the step wizard.
    waiver = @participant_event.consents.find { |c| c.consent_type == "waiver" }
    if all_steps_complete? && !waiver&.participant_portion_signed?
      redirect_to onboarding_waiver_path(event_id: current_event.id)
      return
    end

    current_step = steps[@participant_event.onboarding_step] || steps.first
    redirect_to onboarding_step_path(step: current_step, event_id: current_event.id)
  end

  def show
    @step = params[:step]

    unless steps.include?(@step)
      redirect_to onboarding_path(event_id: current_event.id), alert: "Invalid step."
      return
    end

    @step_index = steps.index(@step)

    # Prevent skipping ahead - users can only access current step or earlier
    if @step_index > @participant_event.onboarding_step
      current_step = steps[@participant_event.onboarding_step] || steps.first
      redirect_to onboarding_step_path(step: current_step, event_id: current_event.id), alert: "Please complete the current step first."
      return
    end

    @steps = steps
    @current_step = @step
    load_step_data

    render "onboarding/#{@step}"
  end

  def update
    @step = params[:step]

    unless steps.include?(@step)
      redirect_to onboarding_path(event_id: current_event.id), alert: "Invalid step."
      return
    end

    @step_index = steps.index(@step)

    # Handle autosave requests - save without validation or advancing
    if params[:autosave] == "true"
      autosave_step_data
      return render json: { success: true, saved_at: Time.current.iso8601 }
    end

    if save_step_data
      advance_to_next_step
      next_step = steps[@participant_event.onboarding_step]

      if next_step
        redirect_to onboarding_step_path(step: next_step, event_id: current_event.id), notice: "Progress saved."
      else
        redirect_to onboarding_step_path(step: REVIEW_STEP, event_id: current_event.id), notice: "All steps complete. Please review your information."
      end
    else
      @steps = steps
      @current_step = @step
      # Only load step data if not already set by save method (preserves user input on error)
      load_step_data unless step_data_loaded?
      flash.now[:alert] ||= "There were some errors with your submission."
      render "onboarding/#{@step}", status: :unprocessable_entity
    end
  end

  def step_data_loaded?
    case @step
    when "travel"
      @travel_inbound.present? && @travel_outbound.present?
    when "profile"
      @participant.present?
    when "accommodation"
      @accommodation.present?
    when "health"
      @medical.present? && @dietary.present? && @accessibility.present?
    when "documents"
      !@documents.nil?
    else
      false
    end
  end

  def waiver
    if Setting.waiver_sending_paused? || current_event.guardian_invites_locked?
      @waiver_paused = true
      return
    end

    ensure_waiver_consent_exists

    @consent = @participant_event.consents.waiver.first

    if @consent.nil? || @consent.failed?
      redirect_to dashboard_path, alert: "Waiver is not ready yet. Please try again later."
      return
    end

    unless @consent.docuseal_participant_slug.present?
      # Waiver creation runs in a background job; show a short auto-refreshing
      # "preparing" state until the signing slug lands (typically a few seconds).
      @waiver_preparing = true
      return
    end

    @signing_url = Docuseal.signing_url(@consent.docuseal_participant_slug, host: @consent.docuseal_host)
  end

  def waiver_complete
    @consent = @participant_event.consents.waiver.first

    pending_docs = @participant_event.pending_custom_documents.select(&:participant_signs?)
    if pending_docs.any?
      redirect_to dashboard_sign_document_path(@participant_event, pending_docs.first),
                  notice: "Waiver signed! A few more documents need your signature."
      return
    end

    # The webhook will mark it as signed, but we redirect immediately
    # so we just go back to dashboard and let them see the updated status
    redirect_to dashboard_path, notice: "Thank you for signing! Your waiver is being processed."
  end

  # Fired by the documents step when an embedded DocuSeal form completes (or
  # to retry a failed one). Sync from the API rather than trusting the client.
  def document_signed
    consent = @participant_event.consents.find(params[:consent_id])

    if params[:retry] == "1" && consent.failed?
      consent.update!(status: :pending, failure_reason: nil, docuseal_envelope_id: nil,
                      docuseal_participant_slug: nil, docuseal_guardian_slug: nil)
    else
      consent.sync_from_docuseal!
    end

    redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id)
  end

  # Polled by the documents step while a document is still outstanding.
  #
  # The embedded form's "completed" event is the fast path, but it's a single
  # point of failure: if it never reaches us — the participant signed in the
  # "open in a new tab" window, the iframe's postMessage was dropped, the
  # signature landed while the tab was backgrounded — the page keeps showing
  # "0 of 1 signed" and a dead Continue button until they think to reload.
  # The webhook has usually already updated the consent by then; nothing was
  # telling the open page about it. This lets the page find out on its own.
  def documents_status
    consents = pollable_document_consents
    consents.each { |c| sync_from_docuseal_throttled(c) }

    render json: {
      signed_consent_ids: consents.select(&:participant_portion_signed?).map { |c| c.id.to_s }.sort
    }
  end

  # Optional documents — waivers for opt-in activities. Adding one is what
  # makes it exist for this participant (and, in turn, for their guardian).
  def add_optional_document
    custom_document = current_event.custom_documents.active.find(params[:custom_document_id])

    unless custom_document.optional? && custom_document.relevant_to?(@participant_event)
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                  alert: "That document isn't available to add."
      return
    end

    enrol_in_optional_document(@participant_event, custom_document)

    redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                notice: "\"#{custom_document.name}\" added."
  end

  def withdraw_optional_document
    custom_document = current_event.custom_documents.active.find(params[:custom_document_id])

    unless custom_document.optional?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                  alert: "That document can't be removed."
      return
    end

    if withdraw_from_optional_document(@participant_event, custom_document).nil?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                  alert: "You haven't added \"#{custom_document.name}\"."
      return
    end

    redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                notice: "\"#{custom_document.name}\" removed. You can add it again any time."
  end

  # Fired by the documents step for physical documents: the participant
  # uploads a photo (or scan) of the form they signed on paper.
  def physical_document_upload
    consent = @participant_event.consents.find(params[:consent_id])
    custom_document = consent.custom_document

    unless custom_document&.physical? && custom_document.participant_signs? && !consent.withdrawn?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), alert: "This document can't be uploaded."
      return
    end

    if consent.signed?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), notice: "This document is already confirmed."
      return
    end

    error = attach_physical_uploads(consent, params.dig(:consent, :physical_uploads))
    if error
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), alert: error
      return
    end

    consent.mark_physical_uploaded_by_participant!

    redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id),
                notice: "\"#{custom_document.name}\" uploaded."
  end

  # Uploads can be swapped out (blurry photo, wrong page) any time before the
  # document is confirmed.
  def remove_physical_upload
    consent = @participant_event.consents.find(params[:consent_id])
    custom_document = consent.custom_document

    unless custom_document&.physical? && custom_document.participant_signs? && !consent.withdrawn?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), alert: "This document can't be updated."
      return
    end

    if consent.signed?
      redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), alert: "This upload can no longer be removed."
      return
    end

    remove_physical_upload_attachment(consent, params[:upload_id])
    redirect_to onboarding_step_path(step: DOCUMENTS_STEP, event_id: current_event.id), notice: "Upload removed."
  end

  def complete
    unless all_steps_complete?
      redirect_to onboarding_path(event_id: current_event.id), alert: "Please complete all steps before submitting."
      return
    end

    unless params[:code_of_conduct_accepted] == "1" && params[:code_of_conduct_signature].present?
      redirect_to onboarding_step_path(step: REVIEW_STEP, event_id: current_event.id), alert: "You must accept the Code of Conduct and Safeguarding Policy and provide your signature."
      return
    end

    @participant_event.update!(
      code_of_conduct_accepted_at: Time.current,
      code_of_conduct_signature: params[:code_of_conduct_signature]
    )

    update_user_name_from_participant
    request_um_review

    if @participant_event.requires_guardian?
      if @participant_event.guardian_participant_events.empty?
        redirect_to onboarding_step_path(step: GUARDIAN_STEP, event_id: current_event.id),
                    alert: "Please add your guardian's details before submitting."
        return
      end

      @participant_event.update!(status: :awaiting_guardian)

      if current_event.guardian_invites_locked? || Setting.waiver_sending_paused?
        redirect_to dashboard_path, notice: completion_notice("Registration submitted! We'll notify you when waivers are ready to sign.")
      elsif waiver_participant_portion_signed?
        # Already signed during the documents step
        send_guardian_invites
        redirect_to dashboard_path, notice: completion_notice("Registration submitted! We've invited your guardian to complete their portion.")
      else
        trigger_minor_waiver
        send_guardian_invites
        redirect_to onboarding_waiver_path(event_id: current_event.id), notice: completion_notice("Almost done! Please sign your waiver, then we'll send it to your guardian.")
      end
    else
      @participant_event.guardian_participant_events.destroy_all if @participant_event.guardian_participant_events.any?

      if @participant_event.emergency_contacts.empty?
        redirect_to onboarding_step_path(step: EMERGENCY_STEP, event_id: current_event.id),
                    alert: "Please add at least one emergency contact before submitting."
        return
      end

      @participant_event.safeguarding_info || @participant_event.create_safeguarding_info!

      if current_event.guardian_invites_locked? || Setting.waiver_sending_paused?
        redirect_to dashboard_path, notice: completion_notice("Registration submitted! We'll notify you when waivers are ready to sign.")
      elsif waiver_participant_portion_signed?
        # Already signed during the documents step — completion lands via
        # webhook/sync now that the code of conduct is accepted.
        @participant_event.mark_complete_if_eligible!
        redirect_to dashboard_path, notice: completion_notice("Registration submitted — you're all set!")
      else
        trigger_adult_waiver
        redirect_to onboarding_waiver_path(event_id: current_event.id), notice: completion_notice("Almost done! Please sign the waiver to complete your registration.")
      end
    end
  end

  private

  def load_participant_event
    participant = current_user.participant
    unless participant
      # Check if a participant with this email already exists (e.g., from CSV import)
      participant = Participant.find_by("LOWER(email) = ?", current_user.email&.downcase)
      if participant
        # Link the existing participant to this user
        participant.update!(user: current_user)
      else
        participant = current_user.build_participant(participant_attrs_from_oidc)
      end
    end

    # Backfill missing fields from OIDC claims for existing participants
    if participant.persisted?
      backfill_participant_from_oidc(participant)
    else
      # Use placeholder values for required fields if OIDC claims are missing
      participant.legal_first_name ||= "Unknown"
      participant.legal_last_name ||= "Unknown"
      participant.save(validate: false)
    end

    unless current_event
      redirect_to dashboard_path, alert: "Please select an event first."
      return
    end

    @participant_event = ParticipantEvent.find_by(participant: participant, event: current_event)

    unless @participant_event
      has_invitation = Invitation.where(event: current_event)
                                 .for_email(current_user.email)
                                 .where("expires_at > ? OR accepted_at IS NOT NULL", Time.current)
                                 .exists?

      unless has_invitation
        redirect_to dashboard_path, alert: "You don't have an invitation for this event."
        return
      end

      @participant_event = ParticipantEvent.create!(
        participant: participant,
        event: current_event,
        status: :in_progress,
        onboarding_step: 0
      )

      # Apply any group memberships specified at invite time
      pending_invitation = Invitation.where(event: current_event)
                                     .for_email(current_user.email)
                                     .where(accepted_at: nil)
                                     .order(created_at: :desc)
                                     .first
      if pending_invitation&.group_ids.present? && current_event.groups_enabled?
        valid_ids = current_event.groups.where(id: pending_invitation.group_ids).pluck(:id)
        valid_ids.each do |gid|
          GroupMembership.find_or_create_by!(group_id: gid, participant_event: @participant_event)
        end
        pending_invitation.accept!
      end
    end

    # CSV-imported participants start with status "invited" — transition to
    # "in_progress" now that they've actually begun onboarding.
    @participant_event.update!(status: :in_progress) if @participant_event.invited?
  end

  def load_step_data
    case @step
    when "profile"
      @participant = @participant_event.participant
    when "travel"
      @travel_inbound = @participant_event.travel_inbound || @participant_event.travels.build(direction: "inbound")
      @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.travel_legs.empty?
      @travel_outbound = @participant_event.travel_outbound || @participant_event.travels.build(direction: "outbound")
      @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.travel_legs.empty?
      @default_inbound_date = current_event.starts_at&.to_date&.strftime("%Y-%m-%d")
      @default_outbound_date = current_event.ends_at&.to_date&.strftime("%Y-%m-%d")
    when "accommodation"
      @accommodation = @participant_event.accommodation || @participant_event.build_accommodation
    when "health"
      @medical = @participant_event.medical || @participant_event.build_medical
      @dietary = @participant_event.dietary || @participant_event.build_dietary
      @accessibility = @participant_event.accessibility || @participant_event.build_accessibility
    when "guardian"
      @guardian_participant_events = @participant_event.guardian_participant_events.includes(:guardian)
      @existing_gpe = @guardian_participant_events.first
      @guardian = @existing_gpe&.guardian || Guardian.new
    when "emergency"
      load_emergency_step_data
    when "documents"
      load_documents_step_data
    when "review"
      load_all_step_data
    end
  end

  def load_all_step_data
    @participant = @participant_event.participant
    @travel_inbound = @participant_event.travel_inbound&.tap { |t| t.travel_legs.load }
    @travel_outbound = @participant_event.travel_outbound&.tap { |t| t.travel_legs.load }
    @accommodation = @participant_event.accommodation
    @medical = @participant_event.medical
    @dietary = @participant_event.dietary
    @accessibility = @participant_event.accessibility
    @guardians = @participant_event.guardian_participant_events.includes(:guardian)
    @emergency_contacts = @participant_event.emergency_contacts.by_priority
  end

  def save_step_data
    case @step
    when "profile"
      @participant = @participant_event.participant
      @participant.assign_attributes(profile_params)
      if profile_params[:tshirt_size].blank?
        flash.now[:alert] = "Please select a t-shirt size"
        return false
      end
      @participant.save
    when "travel"
      save_travel_data
    when "accommodation"
      save_accommodation_data
    when "health"
      save_health_data
    when "guardian"
      save_guardian_data
    when "emergency"
      save_emergency_data
    when "documents"
      save_documents_step
    when "review"
      true
    end
  end

  def autosave_step_data
    case @step
    when "profile"
      # Never re-attach the headshot on autosave. The browser resends the file
      # field on every save, so attaching here would purge and recreate the
      # attachment each time — two overlapping autosaves then deadlock deleting
      # the same active_storage_attachments row. The photo is attached on submit.
      @participant_event.participant.update(profile_params.except(:headshot))
    when "travel"
      autosave_travel_data
    when "accommodation"
      accommodation = @participant_event.accommodation || @participant_event.build_accommodation
      accommodation.update(accommodation_params)
    when "health"
      medical = @participant_event.medical || @participant_event.build_medical
      dietary = @participant_event.dietary || @participant_event.build_dietary
      accessibility = @participant_event.accessibility || @participant_event.build_accessibility
      medical.update(health_medical_params)
      dietary.update(health_dietary_params)
      accessibility.update(health_accessibility_params)
    when "guardian"
      autosave_guardian_data
    when "emergency"
      @participant_event.update(emergency_contacts_params) if params["[emergency_contacts]"].present?
    end
  end

  def autosave_travel_data
    inbound = @participant_event.travel_inbound || @participant_event.travels.build(direction: "inbound")
    outbound = @participant_event.travel_outbound || @participant_event.travels.build(direction: "outbound")

    inbound_params = travel_params(:inbound)
    outbound_params = travel_params(:outbound)

    # Skip legs if not plane mode
    inbound_params.delete(:travel_legs_attributes) if inbound_params[:mode] != "plane"
    outbound_params.delete(:travel_legs_attributes) if outbound_params[:mode] != "plane"

    # For autosave, only update existing legs (those with IDs) to prevent duplicates.
    # New legs without IDs will only be created on final form submission.
    filter_new_legs!(inbound_params)
    filter_new_legs!(outbound_params)

    # Convert manual wall-clock leg times to UTC using their picked/airport timezone
    normalize_leg_times!(inbound_params)
    normalize_leg_times!(outbound_params)

    inbound.update(inbound_params) if inbound_params[:mode].present?
    outbound.update(outbound_params) if outbound_params[:mode].present?
  end

  def filter_new_legs!(travel_params)
    return unless travel_params[:travel_legs_attributes].present?

    travel_params[:travel_legs_attributes] = travel_params[:travel_legs_attributes].select do |_index, leg_attrs|
      leg_attrs[:id].present? || leg_attrs[:_destroy].present?
    end
  end

  def autosave_guardian_data
    return if params[:guardian_email].blank?

    guardian_attrs = {
      legal_first_name: params[:guardian_first_name],
      legal_last_name: params[:guardian_last_name],
      email: params[:guardian_email],
      phone: params[:guardian_phone]
    }

    # Skip autosave if guardian phone matches participant phone
    if guardian_attrs[:phone].present? && @participant_event.participant.phone.present?
      guardian_phone_parsed = Phonelib.parse(guardian_attrs[:phone])
      return if guardian_phone_parsed.valid? && guardian_phone_parsed.e164 == @participant_event.participant.phone
    end

    relationship = params[:guardian_relationship]
    relationship = params[:guardian_relationship_other] if relationship == "Other"

    existing_gpe = @participant_event.guardian_participant_events.first
    if existing_gpe
      existing_gpe.guardian.update(guardian_attrs)
      existing_gpe.update(relationship: relationship) if relationship.present?
    else
      guardian = Guardian.find_or_initialize_by(email: guardian_attrs[:email])
      guardian.assign_attributes(guardian_attrs)
      if guardian.save
        relationship = params[:guardian_relationship]
        relationship = params[:guardian_relationship_other] if relationship == "Other"
        @participant_event.guardian_participant_events.create(guardian: guardian, relationship: relationship)
      end
    end
  end

  def save_travel_data
    @travel_inbound = @participant_event.travel_inbound || @participant_event.travels.build(direction: "inbound")
    @travel_outbound = @participant_event.travel_outbound || @participant_event.travels.build(direction: "outbound")

    inbound_params = travel_params(:inbound)
    outbound_params = travel_params(:outbound)

    errors = []

    # Validate required fields
    if inbound_params[:mode].blank?
      errors << "Please select how you're travelling to Vienna"
    else
      errors.concat(validate_travel_mode_fields(inbound_params, "Arrival"))
    end

    if outbound_params[:mode].blank?
      errors << "Please select how you're leaving Vienna"
    else
      errors.concat(validate_travel_mode_fields(outbound_params, "Departure"))
    end

    # Skip saving legs if not plane mode
    if inbound_params[:mode] != "plane"
      inbound_params.delete(:travel_legs_attributes)
    end
    if outbound_params[:mode] != "plane"
      outbound_params.delete(:travel_legs_attributes)
    end

    # Convert manual wall-clock leg times to UTC using their picked/airport timezone
    normalize_leg_times!(inbound_params)
    normalize_leg_times!(outbound_params)

    # Assign all attributes including travel_legs_attributes for proper nested handling
    @travel_inbound.assign_attributes(inbound_params)
    @travel_outbound.assign_attributes(outbound_params)

    # Declaring the airline UM service requires proof of the booking — this is a
    # hard blocker so unverifiable "I'm under 18 so I'm a UM" claims can't proceed.
    um_declared = um_declared_in?(inbound_params) || um_declared_in?(outbound_params)
    if um_declared && params[:um_proof].blank? && !@participant_event.um_proof.attached?
      errors << "Unaccompanied minor: please upload proof of your UM booking with the airline (e.g. a booking confirmation showing the unaccompanied minor service)"
    end

    if errors.any?
      flash.now[:alert] = errors.join(". ")
      return false
    end

    inbound_saved = @travel_inbound.save
    outbound_saved = @travel_outbound.save

    if inbound_saved && outbound_saved && um_declared && params[:um_proof].present?
      @participant_event.um_proof.attach(params[:um_proof])
      # New evidence always goes back through review, even if previously decided.
      @participant_event.update!(um_status: :pending, um_verified_at: nil, um_verified_by: nil)
    end

    unless inbound_saved && outbound_saved
      errors << "Arrival travel: #{@travel_inbound.errors.full_messages.join(', ')}" if @travel_inbound.errors.any?
      errors << "Departure travel: #{@travel_outbound.errors.full_messages.join(', ')}" if @travel_outbound.errors.any?
      @travel_inbound.travel_legs.each_with_index do |leg, i|
        errors << "Arrival flight leg #{i + 1}: #{leg.errors.full_messages.join(', ')}" if leg.errors.any?
      end
      @travel_outbound.travel_legs.each_with_index do |leg, i|
        errors << "Departure flight leg #{i + 1}: #{leg.errors.full_messages.join(', ')}" if leg.errors.any?
      end
      flash.now[:alert] = errors.join(". ")
    end

    inbound_saved && outbound_saved
  end

  def um_declared_in?(travel_params)
    travel_params[:mode] == "plane" &&
      ActiveRecord::Type::Boolean.new.cast(travel_params[:is_unaccompanied_minor])
  end

  def validate_travel_mode_fields(params, direction)
    errors = []
    mode = params[:mode]

    case mode
    when "plane"
      legs = params[:travel_legs_attributes]&.values || []
      if legs.empty? || legs.all? { |leg| leg[:flight_code].blank? && leg[:departure_airport].blank? }
        errors << "#{direction}: Please enter at least one flight with flight code or airports"
      else
        legs.each_with_index do |leg, i|
          next if leg[:_destroy] == "1"
          leg_errors = []
          leg_errors << "flight code" if leg[:flight_code].blank?
          leg_errors << "departure airport" if leg[:departure_airport].blank?
          leg_errors << "arrival airport" if leg[:arrival_airport].blank?
          leg_errors << "departure time" if leg[:departure_time].blank?
          leg_errors << "arrival time" if leg[:arrival_time].blank?
          if leg_errors.any?
            errors << "#{direction} flight #{i + 1}: Please enter #{leg_errors.join(', ')}"
          end
        end
      end
    when "train"
      leg_errors = []
      leg_errors << "departure station" if params[:train_departure_station].blank?
      leg_errors << "arrival station" if params[:train_arrival_station].blank?
      if direction == "Arrival"
        leg_errors << "arrival time" if params[:arrival_time].blank?
      else
        leg_errors << "departure time" if params[:departure_time].blank?
      end
      if leg_errors.any?
        errors << "#{direction} train: Please enter #{leg_errors.join(', ')}"
      end
    when "bus"
      leg_errors = []
      leg_errors << "departure location" if params[:bus_departure_location].blank?
      leg_errors << "arrival location" if params[:bus_arrival_location].blank?
      leg_errors << "departure time" if params[:departure_time].blank?
      leg_errors << "arrival time" if params[:arrival_time].blank?
      if leg_errors.any?
        errors << "#{direction} bus: Please enter #{leg_errors.join(', ')}"
      end
    when "car"
      leg_errors = []
      leg_errors << "origin/destination address" if params[:origin_address].blank?
      if direction == "Arrival"
        leg_errors << "expected arrival time" if params[:expected_arrival_time].blank?
      else
        leg_errors << "departure time" if params[:departure_time].blank?
      end
      if leg_errors.any?
        errors << "#{direction} car: Please enter #{leg_errors.join(', ')}"
      end
    when "other"
      if params[:other_details].blank?
        errors << "#{direction}: Please describe your travel arrangements"
      end
    end

    errors
  end

  def save_accommodation_data
    @accommodation = @participant_event.accommodation || @participant_event.build_accommodation
    @accommodation.assign_attributes(accommodation_params)

    # Validate required fields
    gender_base = accommodation_params[:gender_base]
    is_transgender = ActiveRecord::Type::Boolean.new.cast(accommodation_params[:is_transgender])

    if gender_base.blank?
      flash.now[:alert] = "Please select your gender identity"
      return false
    end

    # Require preferred roommate genders for non-binary/trans identities
    if gender_base == "non_binary" || is_transgender
      if accommodation_params[:preferred_roommate_genders].blank? || accommodation_params[:preferred_roommate_genders].reject(&:blank?).empty?
        flash.now[:alert] = "Please select which gender(s) you'd like to be paired with"
        return false
      end
    end

    @accommodation.save
  end

  def save_health_data
    @medical = @participant_event.medical || @participant_event.build_medical
    @dietary = @participant_event.dietary || @participant_event.build_dietary
    @accessibility = @participant_event.accessibility || @participant_event.build_accessibility

    @medical.assign_attributes(health_medical_params)
    @dietary.assign_attributes(health_dietary_params)
    @accessibility.assign_attributes(health_accessibility_params)

    @medical.save && @dietary.save && @accessibility.save
  end

  def save_guardian_data
    guardian_attrs = {
      legal_first_name: params[:guardian_first_name],
      legal_last_name: params[:guardian_last_name],
      email: params[:guardian_email],
      phone: params[:guardian_phone]
    }

    relationship = params[:guardian_relationship]
    relationship = params[:guardian_relationship_other] if relationship == "Other"

    if guardian_attrs[:email].blank? || guardian_attrs[:legal_first_name].blank?
      return true
    end

    # Ensure guardian phone is not the same as the participant's phone
    if guardian_attrs[:phone].present? && @participant_event.participant.phone.present?
      guardian_phone_parsed = Phonelib.parse(guardian_attrs[:phone])
      if guardian_phone_parsed.valid? && guardian_phone_parsed.e164 == @participant_event.participant.phone
        flash.now[:alert] = "Guardian phone number cannot be the same as the participant's phone number."
        return false
      end
    end

    existing_gpe = @participant_event.guardian_participant_events.first

    if existing_gpe
      guardian = existing_gpe.guardian
      guardian.assign_attributes(guardian_attrs)

      if guardian.save
        existing_gpe.relationship = relationship
        existing_gpe.update!(invite_token_sent_at: nil) if guardian.email_previously_changed?
        existing_gpe.save
      else
        false
      end
    else
      guardian = Guardian.find_or_initialize_by(email: guardian_attrs[:email])
      guardian.assign_attributes(guardian_attrs)

      if guardian.save
        gpe = @participant_event.guardian_participant_events.create(guardian: guardian, relationship: relationship)
        gpe.persisted?
      else
        false
      end
    end
  end

  def profile_params
    params.fetch(:participant, {}).permit(
      :legal_first_name, :legal_last_name, :preferred_name,
      :email, :phone, :date_of_birth,
      :pronouns, :address_line_1, :address_line_2, :city,
      :state, :postal_code, :country_of_residence, :tshirt_size,
      :headshot, :engagement_preference, :engagement_notes
    )
  end

  def travel_params(direction)
    params.fetch("travel_#{direction}", {}).permit(
      :mode, :carrier, :flight_number, :departure_city, :departure_time,
      :arrival_city, :arrival_time, :needs_pickup, :notes, :is_unaccompanied_minor,
      :train_departure_station, :train_arrival_station,
      :bus_departure_location, :bus_arrival_location,
      :origin_address, :expected_arrival_time, :other_details, :visa_status,
      travel_legs_attributes: [ :id, :position, :flight_code, :departure_airport, :arrival_airport,
                               :departure_time, :departure_time_zone, :arrival_time, :arrival_time_zone, :confirmation_code, :_destroy ]
    )
  end

  def accommodation_params
    params.fetch(:accommodation, {}).permit(
      :gender_identity, :gender_identity_other, :gender_base, :is_transgender, :roommate_preferences, :roommate_exclusions,
      preferred_roommate_genders: []
    )
  end

  def health_medical_params
    params.permit(
      :allergies, :medical_conditions, :medications,
      :has_anaphylaxis_risk, :requires_refrigeration
    )
  end

  def health_dietary_params
    permitted = params.permit(:diet_type, :intolerances, :life_threatening_allergies)
    # Convert empty string to nil for enum field
    permitted[:diet_type] = nil if permitted[:diet_type].blank?
    permitted
  end

  def health_accessibility_params
    params.permit(
      :has_adhd, :has_dyslexia, :has_autism, :neurodivergent_notes,
      :uses_wheelchair, :step_free_required, :needs_large_print,
      :needs_captioning, :needs_sign_language, :other_needs
    )
  end

  def load_emergency_step_data
    @participant = @participant_event.participant
    @safeguarding_info = @participant_event.safeguarding_info || @participant_event.build_safeguarding_info
    @emergency_contacts = @participant_event.emergency_contacts.by_priority.to_a
    @emergency_contacts << @participant_event.emergency_contacts.build(priority: 1) if @emergency_contacts.empty?
  end

  def save_emergency_data
    errors = []

    ActiveRecord::Base.transaction do
      safeguarding_info = @participant_event.safeguarding_info || @participant_event.build_safeguarding_info

      unless safeguarding_info.save
        errors << "Safeguarding info: #{safeguarding_info.errors.full_messages.join(', ')}"
        raise ActiveRecord::Rollback
      end

      unless @participant_event.update(emergency_contacts_params)
        errors << "Emergency contacts: #{@participant_event.errors.full_messages.join(', ')}"
        raise ActiveRecord::Rollback
      end

      if @participant_event.emergency_contacts.reload.empty?
        errors << "Please add at least one emergency contact"
        raise ActiveRecord::Rollback
      end

      return true
    end

    load_emergency_step_data
    flash.now[:alert] = errors.join(". ")
    false
  end

  def emergency_contacts_params
    # form_with url: wraps fields_for names in brackets, so the key is literally "[emergency_contacts]"
    raw_contacts = params["[emergency_contacts]"]
    return {} if raw_contacts.blank?

    permitted_contacts = {}
    raw_contacts.each do |index, contact_params|
      permitted_contacts[index] = contact_params.permit(
        :id, :name, :phone, :email, :relationship, :priority, :_destroy
      )
    end

    { emergency_contacts_attributes: permitted_contacts }
  end

  def steps
    @steps_list ||= begin
      s = BASE_STEPS.dup
      s.delete("travel") unless current_event.travel_enabled?
      s.delete("accommodation") unless current_event.accommodation_enabled?
      if @participant_event.requires_guardian?
        s << GUARDIAN_STEP
      else
        s << EMERGENCY_STEP
      end
      s << DOCUMENTS_STEP
      s << REVIEW_STEP
      s
    end
  end

  def advance_to_next_step
    next_step_index = @step_index + 1
    if next_step_index < steps.length && next_step_index > @participant_event.onboarding_step
      @participant_event.update!(onboarding_step: next_step_index)
    end
  end

  def all_steps_complete?
    @participant_event.onboarding_step >= steps.length - 1
  end

  def completion_notice(base)
    return base unless @participant_event.unaccompanied_minor_declared?

    "#{base} Since you're travelling as an unaccompanied minor, we'll reach out to you with pickup/dropoff information within 2 weeks of the event."
  end

  # Marks the UM declaration pending on submit. The reviewer email itself only
  # goes out once the guardian has double-confirmed the airline booking
  # (see ParticipantEvent#request_um_review!) — usually from the guardian
  # portal, but here too in case the guardian confirmed before resubmission.
  def request_um_review
    return unless @participant_event.unaccompanied_minor_declared?

    @participant_event.update!(um_status: :pending) if @participant_event.um_none?
    @participant_event.request_um_review!
  end

  def trigger_adult_waiver
    consent = @participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
      c.status = :pending
    end

    if consent.failed?
      consent.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
    elsif !consent.signed? && consent.docuseal_participant_slug.blank?
      # perform_later: the DocuSeal round-trip must not block the review-submit
      # request. The waiver page shows a brief "preparing" state until the job
      # has stored the signing slug.
      DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
    end
  end

  def trigger_minor_waiver
    guardian_participant_event = @participant_event.guardian_participant_events.first
    return unless guardian_participant_event

    consent = @participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
      c.status = :pending
      c.guardian_participant_event = guardian_participant_event
    end

    unless consent.signed? || consent.sent?
      DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id)
    end

    if consent.failed?
      consent.update!(status: :pending, failure_reason: nil)
      DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id)
    end
  end

  def waiver_participant_portion_signed?
    @participant_event.consents.any? { |c| c.consent_type == "waiver" && c.participant_portion_signed? }
  end

  # Exactly the consents the documents step renders a row for — the same set,
  # in the same order, as the @documents it builds. It has to match: the page
  # reloads as soon as this answer differs from what it was rendered with, so
  # a consent the page never showed (a withdrawn optional document, say)
  # would otherwise put it in a reload loop.
  def pollable_document_consents
    consents = @participant_event.consents.reload
    document_ids = @participant_event.applicable_custom_documents.select(&:participant_signs?).map(&:id)

    [
      consents.find { |c| c.consent_type == "waiver" },
      *document_ids.map { |id| consents.find { |c| c.custom_document_id == id } }
    ].compact
  end

  # Poll interval is a few seconds; hitting the DocuSeal API that often for
  # every outstanding document would be rude, and the webhook usually gets
  # there first anyway. Sync at most once per consent per window — the plain
  # DB read on every poll is what actually carries the webhook's update
  # through to the page.
  DOCUSEAL_POLL_THROTTLE = 15.seconds

  def sync_from_docuseal_throttled(consent)
    return if consent.participant_portion_signed?
    return if consent.docuseal_envelope_id.blank?

    key = "docuseal_status_poll/#{consent.id}"
    return if Rails.cache.read(key)
    Rails.cache.write(key, true, expires_in: DOCUSEAL_POLL_THROTTLE)

    consent.sync_from_docuseal!
  end

  def load_documents_step_data
    @documents_paused = Setting.waiver_sending_paused? || current_event.guardian_invites_locked?
    @missing_guardian = @participant_event.requires_guardian? && @participant_event.guardian_participant_events.empty?

    unless @documents_paused || @missing_guardian
      ensure_waiver_consent_exists
      ensure_custom_document_consents_exist
    end

    # Signatures normally land via webhook or the embedded form's completion
    # callback; also pull pending ones from the API so documents signed in
    # another tab show up on reload.
    @participant_event.consents.reload.each do |c|
      next unless c.consent_type == "waiver" || c.custom_document_id.present?
      c.sync_from_docuseal! if c.docuseal_envelope_id.present? && !c.participant_portion_signed?
    end

    consents = @participant_event.consents.reload
    @documents = [ { name: "Event Waiver", consent: consents.find { |c| c.consent_type == "waiver" } } ]
    @participant_event.applicable_custom_documents.select(&:participant_signs?).each do |doc|
      @documents << { name: doc.name, consent: consents.find { |c| c.custom_document_id == doc.id }, custom_document: doc }
    end

    # Optional activity waivers. Offered here, but never gating the step —
    # skipping them is the whole point.
    @optional_documents = @participant_event.relevant_optional_custom_documents

    pending = @documents.reject { |d| d[:consent]&.participant_portion_signed? }
    # Physical documents are downloaded/uploaded rather than signed embedded,
    # so they never become the "current" DocuSeal document and never count as
    # "preparing" (no submission is ever created for them).
    electronic_pending = pending.reject { |d| d[:custom_document]&.physical? }
    @physical_pending = pending.select { |d| d[:custom_document]&.physical? }
    @current_document = electronic_pending.find { |d| d[:consent]&.docuseal_participant_slug.present? && !d[:consent].failed? }
    @failed_document = electronic_pending.find { |d| d[:consent]&.failed? }
    @documents_preparing = @current_document.nil? && !@documents_paused && !@missing_guardian &&
                           electronic_pending.any? { |d| d[:consent].nil? || (!d[:consent].failed? && d[:consent].docuseal_participant_slug.blank?) }
    @all_documents_signed = pending.empty?
  end

  def save_documents_step
    load_documents_step_data
    return true if @documents_paused || @missing_guardian
    return true if @all_documents_signed

    flash.now[:alert] = "Please sign all documents before continuing."
    false
  end

  def ensure_custom_document_consents_exist
    @participant_event.applicable_custom_documents.select(&:participant_signs?).each do |doc|
      consent = @participant_event.consents.find_or_create_by!(consent_type: :custom_document, custom_document: doc)
      # Physical documents are signed on paper — no DocuSeal submission.
      next if doc.physical?

      if consent.docuseal_envelope_id.blank? && !consent.signed? && !consent.failed?
        DocusealJobs::CreateCustomDocumentJob.perform_later(consent.id)
      end
    end
  end

  def ensure_waiver_consent_exists
    if @participant_event.requires_guardian?
      guardian_participant_event = @participant_event.guardian_participant_events.first
      return unless guardian_participant_event

      consent = @participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
        c.guardian_participant_event = guardian_participant_event
      end

      if consent.docuseal_participant_slug.blank? && !consent.signed? && !consent.failed?
        DocusealJobs::CreateMinorWaiverJob.perform_later(consent.id)
      end
    else
      consent = @participant_event.consents.find_or_create_by!(consent_type: :waiver) do |c|
        c.status = :pending
      end

      if consent.docuseal_participant_slug.blank? && !consent.signed? && !consent.failed?
        DocusealJobs::CreateAdultWaiverJob.perform_later(consent.id)
      end
    end
  end

  def send_guardian_invites
    return if @participant_event.event.guardian_invites_locked?

    @participant_event.guardian_participant_events.each do |gpe|
      next if gpe.invite_token_sent_at.present?

      GuardianMailer.invitation(guardian_participant_event: gpe).deliver_later
    end
  end

  def redirect_if_withdrawn
    return unless @participant_event&.withdrawn?

    redirect_to dashboard_path, alert: "Your registration has been withdrawn from this event."
  end

  def redirect_if_locked
    return unless @participant_event.awaiting_guardian? || @participant_event.complete?

    # Allow minors whose guardian was never linked to go back and add one
    if @participant_event.awaiting_guardian? && @participant_event.guardian_participant_events.empty?
      @participant_event.update!(status: :in_progress)
      return
    end

    redirect_to dashboard_path, alert: "Your registration has been submitted and cannot be edited."
  end

  def store_invitation_token
    return unless params[:invite].present?

    session[:invitation_token] = params[:invite]
  end

  def process_invitation
    # First, check for explicit event_id parameter (used for "Continue Onboarding" links)
    if params[:event_id].present?
      event = Event.find_by(id: params[:event_id])
      if event
        set_current_event(event)
        return
      end
    end

    # Then, check for invitation token
    token = params[:invite] || session[:invitation_token]
    return unless token

    invitation = Invitation.find_by(token: token)
    return unless invitation

    if invitation.expired?
      redirect_to dashboard_path, alert: "This invitation has expired. Please contact the event organizers."
      return
    end

    session[:invitation_token] = token
    set_current_event(invitation.event)

    unless invitation.accepted?
      invitation.accept! if current_user.email.downcase == invitation.email.downcase
    end
  end

  def backfill_participant_from_oidc(participant)
    oidc_attrs = participant_attrs_from_oidc
    updates = {}

    # Only backfill fields that are blank/placeholder
    updates[:legal_first_name] = oidc_attrs[:legal_first_name] if participant.legal_first_name.blank? || participant.legal_first_name == "Unknown"
    updates[:legal_last_name] = oidc_attrs[:legal_last_name] if participant.legal_last_name.blank? || participant.legal_last_name == "Unknown"
    updates[:preferred_name] = oidc_attrs[:preferred_name] if participant.preferred_name.blank? && oidc_attrs[:preferred_name].present?
    updates[:phone] = oidc_attrs[:phone] if participant.phone.blank? && oidc_attrs[:phone].present?
    updates[:date_of_birth] = oidc_attrs[:date_of_birth] if participant.date_of_birth.blank? && oidc_attrs[:date_of_birth].present?
    updates[:address_line_1] = oidc_attrs[:address_line_1] if participant.address_line_1.blank? && oidc_attrs[:address_line_1].present?
    updates[:address_line_2] = oidc_attrs[:address_line_2] if participant.address_line_2.blank? && oidc_attrs[:address_line_2].present?
    updates[:city] = oidc_attrs[:city] if participant.city.blank? && oidc_attrs[:city].present?
    updates[:state] = oidc_attrs[:state] if participant.state.blank? && oidc_attrs[:state].present?
    updates[:postal_code] = oidc_attrs[:postal_code] if participant.postal_code.blank? && oidc_attrs[:postal_code].present?
    updates[:country_of_residence] = oidc_attrs[:country_of_residence] if participant.country_of_residence.blank? && oidc_attrs[:country_of_residence].present?

    participant.update(updates) if updates.present?
  end

  def participant_attrs_from_oidc
    claims = current_user.oidc_claims || {}
    address = claims["address"] || {}

    # Prefer legal names from HCA API, fall back to given/family name
    first_name = claims["legal_first_name"].presence || claims["given_name"].presence
    last_name = claims["legal_last_name"].presence || claims["family_name"].presence

    attrs = {
      email: current_user.email,
      legal_first_name: first_name,
      legal_last_name: last_name
    }

    attrs[:preferred_name] = claims["preferred_name"] if claims["preferred_name"].present?
    attrs[:phone] = claims["phone_number"] if claims["phone_number"].present?
    attrs[:date_of_birth] = Date.parse(claims["birthdate"]) if claims["birthdate"].present?

    # Handle both HCA API format (line_1) and OIDC format (street_address)
    attrs[:address_line_1] = address["line_1"] || address["street_address"] if (address["line_1"] || address["street_address"]).present?
    attrs[:address_line_2] = address["line_2"] if address["line_2"].present?
    attrs[:city] = address["city"] || address["locality"] if (address["city"] || address["locality"]).present?
    attrs[:state] = address["state"] || address["region"] if (address["state"] || address["region"]).present?
    attrs[:postal_code] = address["postal_code"] if address["postal_code"].present?
    attrs[:country_of_residence] = address["country"] if address["country"].present?

    attrs
  rescue Date::Error
    attrs
  end

  def update_user_name_from_participant
    participant = @participant_event.participant
    display_name = [ participant.preferred_name.presence || participant.legal_first_name, participant.legal_last_name ].compact.join(" ")
    current_user.update!(name: display_name) if display_name.present?
  end

  def force_html_format
    request.format = :html
  end
end
