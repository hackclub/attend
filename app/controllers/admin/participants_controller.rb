module Admin
  class ParticipantsController < BaseController
    include TravelLegDateMerging

    before_action :require_event_selected
    before_action :set_participant_event, except: [ :index, :table, :new_invite, :send_invite, :revoke_invite, :sync_slack_channel_preview, :sync_slack_channel ]
    before_action :set_participant_header_data, only: [ :show, :travel, :update_travel, :accommodation, :update_accommodation, :medical, :update_medical, :safeguarding, :update_safeguarding, :consents, :notes, :history, :slack_invite_link, :merge ]
    before_action :require_safeguarding_access, only: [ :safeguarding ]

    def index
      authorize ParticipantEvent

      @show_pending_invitations = params[:status] == "pending_invitations"

      if @show_pending_invitations
        @pending_invitations = current_event.invitations.pending.order(created_at: :desc)

        if params[:search].present?
          search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
          @pending_invitations = @pending_invitations.where("email ILIKE ?", search_term)
        end

        @participant_events = current_event.participant_events.none
      else
        # preload (not includes): the string order on participants.legal_last_name
        # would otherwise flip every association into one giant eager-load LEFT JOIN.
        @participant_events = policy_scope(current_event.participant_events)
          .preload(:participant, :event, :travel_inbound, :travel_outbound, :accommodation, :medical, :safeguarding_info, :dietary, :accessibility, :consents, :emergency_contacts, :groups, guardian_participant_events: :emergency_contacts)

        if params[:search].present?
          search_term = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
          @participant_events = @participant_events.joins(:participant).where(
            "participants.legal_first_name ILIKE :term OR " \
            "participants.legal_last_name ILIKE :term OR " \
            "participants.preferred_name ILIKE :term OR " \
            "participants.email ILIKE :term",
            term: search_term
          )
        end

        if params[:status].present?
          status_filter = case params[:status]
          when "awaiting_participant" then %w[invited in_progress]
          when "awaiting_parent"     then %w[awaiting_guardian]
          else params[:status]
          end
          @participant_events = @participant_events.where(status: status_filter)
        end
      end

      if params[:flag].present?
        case params[:flag]
        when "incomplete_onboarding"
          @participant_events = @participant_events.missing_onboarding_data(accommodation_required: current_event.accommodation_enabled?)
        when "missing_travel"
          @participant_events = @participant_events.left_joins(:travel_inbound).where(travels: { id: nil })
        when "missing_medical"
          @participant_events = @participant_events.left_joins(:medical).where(medicals: { id: nil })
        when "high_support"
          @participant_events = @participant_events.joins(:safeguarding_info).where(safeguarding_infos: { high_support_flag: true })
        when "anaphylaxis"
          @participant_events = @participant_events.joins(:medical).where(medicals: { has_anaphylaxis_risk: true })
        end
      end

      if current_event.groups_enabled? && params[:group_id].present?
        if @participant_events.is_a?(ActiveRecord::Relation)
          if params[:group_id] == "none"
            @participant_events = @participant_events.where.not(id: GroupMembership.select(:participant_event_id))
          else
            @participant_events = @participant_events.where(id: GroupMembership.where(group_id: params[:group_id]).select(:participant_event_id))
          end
        end
      end

      if params[:checked_in].present?
        case params[:checked_in]
        when "yes"
          checked_in_ids = Scan.for_check_in.joins(:participant_event)
            .where(participant_events: { event_id: current_event.id })
            .select(:participant_event_id).distinct
          @participant_events = @participant_events.where(id: checked_in_ids)
        when "no"
          checked_in_ids = Scan.for_check_in.joins(:participant_event)
            .where(participant_events: { event_id: current_event.id })
            .select(:participant_event_id).distinct
          @participant_events = @participant_events.where.not(id: checked_in_ids)
        end
      end

      @participant_events = @participant_events.joins(:participant).order("participants.legal_last_name ASC") if @participant_events.is_a?(ActiveRecord::Relation)
    end

    def table
      authorize ParticipantEvent

      @participant_events = policy_scope(current_event.participant_events)
        .includes(
          participant: [],
          travel_inbound: :travel_legs,
          travel_outbound: :travel_legs,
          accommodation: [],
          medical: [],
          dietary: [],
          accessibility: [],
          safeguarding_info: [],
          consents: [],
          emergency_contacts: [],
          event: [],
          guardian_participant_events: [ :guardian, :emergency_contacts ],
          scans: [ :scan_context, :user ],
          groups: []
        )
        .preload(room: { participant_events: :participant })

      @sort_field = params[:sort] || "legal_last_name"
      @sort_direction = params[:direction] == "desc" ? "desc" : "asc"
      @group_by = params[:group_by].presence || "status"

      @scan_contexts = current_event.scan_contexts.to_a

      @participant_events = apply_table_filters(@participant_events)
      @participant_events = apply_table_sorting(@participant_events)

      if @group_by.present? && @group_by != "none"
        @grouped_participants = group_participants(@participant_events)
      end
    end

    def show
      authorize @participant_event
      @participant = @participant_event.participant
      @participant.user&.sync_slack_id_to_participant
      @travel_inbound = @participant_event.travel_inbound&.tap { |t| t.travel_legs.load }
      @travel_outbound = @participant_event.travel_outbound&.tap { |t| t.travel_legs.load }
      @accommodation = @participant_event.accommodation
      @medical = @participant_event.medical
      @dietary = @participant_event.dietary
      @accessibility = @participant_event.accessibility
      @safeguarding_info = @participant_event.safeguarding_info
      @consents = @participant_event.consents
      @guardian_participant_events = @participant_event.guardian_participant_events.includes(:guardian)
      @notes = @participant_event.notes.includes(:author).order(created_at: :desc)
      @scans = @participant_event.scans.includes(:user, :scan_context).recent.limit(3)
    end

    def link_guardian
      authorize @participant_event, :update?

      guardian = Guardian.find_or_initialize_by(email: params[:guardian_email].strip.downcase)
      guardian.assign_attributes(
        legal_first_name: params[:guardian_first_name],
        legal_last_name: params[:guardian_last_name],
        phone: params[:guardian_phone]
      )

      if guardian.save
        gpe = @participant_event.guardian_participant_events.create(
          guardian: guardian,
          relationship: params[:guardian_relationship]
        )

        if gpe.persisted?
          redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Guardian linked successfully."
        else
          redirect_to admin_event_participant_path(current_event, @participant_event), alert: "Guardian already linked to this participant."
        end
      else
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "Could not save guardian: #{guardian.errors.full_messages.join(', ')}"
      end
    end

    def edit
      authorize @participant_event, :update?
      @participant = @participant_event.participant
    end

    def update
      authorize @participant_event, :update?
      @participant = @participant_event.participant

      if @participant.update(participant_params)
        @record = @participant
        redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Participant updated successfully."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def travel
      authorize @participant_event, :view_travel?
      @travel_inbound = @participant_event.travel_inbound&.tap { |t| t.travel_legs.load } || @participant_event.build_travel_inbound
      @travel_outbound = @participant_event.travel_outbound&.tap { |t| t.travel_legs.load } || @participant_event.build_travel_outbound
      @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.plane? && @travel_inbound.travel_legs.empty?
      @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.plane? && @travel_outbound.travel_legs.empty?
    end

    def update_travel
      authorize @participant_event, :update_travel?
      @travel_inbound = @participant_event.travel_inbound || @participant_event.build_travel_inbound
      @travel_outbound = @participant_event.travel_outbound || @participant_event.build_travel_outbound

      Travel.transaction do
        inbound_saved = @travel_inbound.update(travel_params(:inbound))
        outbound_saved = @travel_outbound.update(travel_params(:outbound))

        if inbound_saved && outbound_saved
          redirect_to travel_admin_event_participant_path(current_event, @participant_event), notice: "Travel information updated."
        else
          @travel_inbound.travel_legs.build(position: 0) if @travel_inbound.plane? && @travel_inbound.travel_legs.reject(&:marked_for_destruction?).empty?
          @travel_outbound.travel_legs.build(position: 0) if @travel_outbound.plane? && @travel_outbound.travel_legs.reject(&:marked_for_destruction?).empty?
          render :travel, status: :unprocessable_entity
        end
      end
    end

    def approve_um
      authorize @participant_event, :update_travel?
      @participant_event.approve_um!(user: current_user)
      Rails.cache.delete("airport_mode/#{current_event.id}/journeys/v3")
      redirect_to travel_admin_event_participant_path(current_event, @participant_event), notice: "Unaccompanied minor status approved."
    end

    def reject_um
      authorize @participant_event, :update_travel?
      @participant_event.reject_um!(user: current_user)
      Rails.cache.delete("airport_mode/#{current_event.id}/journeys/v3")
      redirect_to travel_admin_event_participant_path(current_event, @participant_event), notice: "Unaccompanied minor status rejected."
    end

    def um_proof
      authorize @participant_event, :view_travel?
      unless @participant_event.um_proof.attached?
        redirect_to travel_admin_event_participant_path(current_event, @participant_event), alert: "No UM proof uploaded."
        return
      end

      redirect_to rails_blob_path(@participant_event.um_proof, disposition: "inline")
    end

    def accommodation
      authorize @participant_event, :view_accommodation?
      @accommodation = @participant_event.accommodation || @participant_event.build_accommodation
    end

    def update_accommodation
      authorize @participant_event, :update_accommodation?
      @accommodation = @participant_event.accommodation || @participant_event.build_accommodation

      if @accommodation.update(accommodation_params)
        redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Accommodation updated."
      else
        render :accommodation, status: :unprocessable_entity
      end
    end

    def medical
      authorize @participant_event, :view_medical?
      unless can_access_medical?
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "You are not authorized to view medical information."
        return
      end

      @medical = @participant_event.medical || @participant_event.build_medical
      @dietary = @participant_event.dietary || @participant_event.build_dietary
      @accessibility = @participant_event.accessibility || @participant_event.build_accessibility
    end

    def update_medical
      authorize @participant_event, :update_medical?
      unless can_access_medical?
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "You are not authorized to update medical information."
        return
      end

      @medical = @participant_event.medical || @participant_event.build_medical
      @dietary = @participant_event.dietary || @participant_event.build_dietary
      @accessibility = @participant_event.accessibility || @participant_event.build_accessibility

      ActiveRecord::Base.transaction do
        @medical.assign_attributes(medical_params)
        @dietary.assign_attributes(dietary_params)
        @accessibility.assign_attributes(accessibility_params)

        if @medical.save && @dietary.save && @accessibility.save
          redirect_to medical_admin_event_participant_path(current_event, @participant_event), notice: "Medical information updated."
        else
          raise ActiveRecord::Rollback
        end
      end

      render :medical, status: :unprocessable_entity if response.committed? == false && !performed?
    end

    def safeguarding
      authorize @participant_event, :view_safeguarding?
      @safeguarding_info = @participant_event.safeguarding_info || @participant_event.build_safeguarding_info
      @guardians = @participant_event.guardians.includes(:guardian_participant_events)
      @emergency_contacts = EmergencyContact.left_joins(:guardian_participant_event).where(
        "emergency_contacts.participant_event_id = :pe_id OR guardian_participant_events.participant_event_id = :pe_id",
        pe_id: @participant_event.id
      )
    end

    def update_safeguarding
      authorize @participant_event, :update_safeguarding?
      @safeguarding_info = @participant_event.safeguarding_info || @participant_event.build_safeguarding_info
      @guardians = @participant_event.guardians.includes(:guardian_participant_events)
      @emergency_contacts = EmergencyContact.left_joins(:guardian_participant_event).where(
        "emergency_contacts.participant_event_id = :pe_id OR guardian_participant_events.participant_event_id = :pe_id",
        pe_id: @participant_event.id
      )

      if @safeguarding_info.update(safeguarding_params)
        redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Safeguarding information updated."
      else
        render :safeguarding, status: :unprocessable_entity
      end
    end

    def consents
      authorize @participant_event, :view_consents?
      @consents = @participant_event.consents.includes(:guardian_participant_event).order(:consent_type)

      # Applicable custom documents get their own section — including ones with
      # no consent row yet (consents are created lazily when someone opens the
      # document, so a doc nobody has touched would otherwise be invisible here).
      @custom_documents = @participant_event.applicable_custom_documents
      @custom_document_consents = @consents.select { |c| c.custom_document_id.present? }.index_by(&:custom_document_id)
      # Optional documents on offer that this participant hasn't taken up.
      # Listed separately so "no waiver on file" reads as "not doing the
      # activity" rather than as a chase-up.
      @unadded_optional_documents = @participant_event.available_optional_custom_documents
    end

    def reset_waiver
      authorize @participant_event, :reset_waiver?

      waiver_consent = @participant_event.consents.find_by(consent_type: :waiver)
      if waiver_consent
        waiver_consent.update!(
          status: :pending,
          docuseal_envelope_id: nil,
          docuseal_guardian_slug: nil,
          docuseal_participant_slug: nil,
          docuseal_template_id: nil,
          guardian_signed_at: nil,
          participant_signed_at: nil,
          signed_at: nil,
          document_url: nil,
          failure_reason: nil
        )

        reopen_guardian_portal_access
        send_waiver_reset_email(waiver_type: :waiver)

        notice = if @participant_event.requires_guardian?
          "Waiver has been reset and the guardian has been emailed. A new waiver will be generated when they visit the portal."
        else
          "Waiver has been reset and the participant has been emailed. A new waiver will be generated when they visit the portal."
        end

        redirect_to consents_admin_event_participant_path(current_event, @participant_event), notice: notice
      else
        redirect_to consents_admin_event_participant_path(current_event, @participant_event),
          alert: "No waiver found to reset."
      end
    end

    def reset_freedom_waiver
      authorize @participant_event, :reset_waiver?

      freedom_waiver_consent = @participant_event.consents.find_by(consent_type: :freedom_waiver)
      if freedom_waiver_consent
        freedom_waiver_consent.update!(
          status: :pending,
          docuseal_envelope_id: nil,
          docuseal_guardian_slug: nil,
          docuseal_participant_slug: nil,
          docuseal_template_id: nil,
          guardian_signed_at: nil,
          participant_signed_at: nil,
          signed_at: nil,
          document_url: nil,
          failure_reason: nil
        )

        @participant_event.safeguarding_info&.update!(freedom_waiver_granted: false)

        reopen_guardian_portal_access
        send_waiver_reset_email(waiver_type: :freedom_waiver)

        notice = if @participant_event.requires_guardian?
          "Freedom waiver has been reset and the guardian has been emailed. A new waiver will be generated when they visit the portal."
        else
          "Freedom waiver has been reset and the participant has been emailed. A new waiver will be generated when they visit the portal."
        end

        redirect_to consents_admin_event_participant_path(current_event, @participant_event), notice: notice
      else
        redirect_to consents_admin_event_participant_path(current_event, @participant_event),
          alert: "No freedom waiver found to reset."
      end
    end

    def resend_waiver_completion_email
      authorize @participant_event, :reset_waiver?

      waiver_consent = @participant_event.consents.find_by(consent_type: :waiver)

      unless waiver_consent&.signed?
        redirect_to consents_admin_event_participant_path(current_event, @participant_event),
          alert: "Cannot resend: waiver is not fully signed."
        return
      end

      if @participant_event.requires_guardian?
        guardian_participant_event = @participant_event.guardian_participant_events.first
        unless guardian_participant_event
          redirect_to consents_admin_event_participant_path(current_event, @participant_event),
            alert: "Cannot resend: no guardian found."
          return
        end

        GuardianMailer.waiver_completion(guardian_participant_event: guardian_participant_event).deliver_later
        redirect_to consents_admin_event_participant_path(current_event, @participant_event),
          notice: "Waiver completion email resent to guardian."
      else
        ParticipantMailer.adult_waiver_completion(participant_event: @participant_event).deliver_later
        redirect_to consents_admin_event_participant_path(current_event, @participant_event),
          notice: "Waiver completion email resent to participant."
      end
    end

    def notes
      authorize @participant_event, :view_notes?
      @notes = @participant_event.notes.includes(:author).order(created_at: :desc)
    end

    def history
      authorize @participant_event, :show?

      pe = @participant_event
      participant = pe.participant
      gpes = pe.guardian_participant_events.to_a
      guardian_ids = gpes.map(&:guardian_id).compact
      gpe_ids = gpes.map(&:id)

      keys = []
      keys << [ "ParticipantEvent", [ pe.id ] ]
      keys << [ "Participant", [ participant.id ] ]
      keys << [ "GuardianParticipantEvent", gpe_ids ] if gpe_ids.any?
      keys << [ "Guardian", guardian_ids ] if guardian_ids.any?
      keys << [ "Medical", Array(pe.medical&.id) ]
      keys << [ "Dietary", Array(pe.dietary&.id) ]
      keys << [ "Accessibility", Array(pe.accessibility&.id) ]
      keys << [ "SafeguardingInfo", Array(pe.safeguarding_info&.id) ]
      keys << [ "Accommodation", Array(pe.accommodation&.id) ]
      keys << [ "Travel", pe.travels.pluck(:id) ]
      keys << [ "TravelLeg", TravelLeg.where(travel_id: pe.travels.pluck(:id)).pluck(:id) ]
      keys << [ "Consent", pe.consents.pluck(:id) ]
      keys << [ "Note", pe.notes.pluck(:id) ]
      keys << [ "EmergencyContact", EmergencyContact.where(participant_event_id: pe.id).or(EmergencyContact.where(guardian_participant_event_id: gpe_ids)).pluck(:id) ]
      keys << [ "RoomAssignment", Array(pe.room_assignment&.id) ]
      keys << [ "RoommatePreference", pe.roommate_preferences.pluck(:id) ]
      keys << [ "RoommateExclusion", pe.roommate_exclusions.pluck(:id) ]

      conditions = keys.reject { |_, ids| ids.blank? }
      if conditions.any?
        clauses = conditions.map { "(item_type = ? AND item_id IN (?))" }.join(" OR ")
        binds = conditions.flat_map { |type, ids| [ type, ids ] }
        @versions = PaperTrail::Version.where(clauses, *binds).order(created_at: :desc).limit(500)
      else
        @versions = PaperTrail::Version.none
      end

      whodunnit_ids = @versions.map(&:whodunnit).compact.uniq
      @users_by_id = User.where(id: whodunnit_ids).index_by(&:id)
    end

    # Live flight tracking (OAG) was removed to cut cost. These endpoints are
    # kept so any stale links/bookmarks fail gracefully instead of 404ing, but
    # they no longer call any external flight API — flight data is manual now.
    def refresh_flight_tracking
      authorize @participant_event, :update_travel?
      redirect_to travel_admin_event_participant_path(current_event, @participant_event),
        alert: "Live flight tracking is disabled. Flight details are entered manually."
    end

    def refresh_flight_leg
      authorize @participant_event, :update_travel?
      respond_to do |format|
        format.json { render json: { success: false, error: "Live flight tracking is disabled." }, status: :gone }
        format.html do
          redirect_back fallback_location: travel_admin_event_participant_path(current_event, @participant_event),
            alert: "Live flight tracking is disabled. Flight details are entered manually."
        end
      end
    end

    def send_travel_update_reminder
      authorize @participant_event, :update_travel?

      ParticipantMailer.travel_update_reminder(participant_event: @participant_event).deliver_later
      redirect_to admin_event_participant_path(current_event, @participant_event),
        notice: "Travel update reminder sent to #{@participant_event.participant.email}."
    end

    def resync_airtable
      authorize @participant_event, :resync_external?
      AirtableJobs::PushRecordJob.perform_later(@participant_event.id)
      redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Airtable sync queued."
    end

    def withdraw
      authorize @participant_event, :update?
      @participant_event.withdrawn!
      redirect_to admin_event_participant_path(current_event, @participant_event),
        notice: "#{@participant_event.participant.display_name} has been marked as withdrawn."
    end

    def unwithdraw
      authorize @participant_event, :update?
      # Reset to a non-terminal status; #display_status recomputes the real state
      # (Awaiting Participant / Awaiting Parent / Complete) from onboarding progress.
      @participant_event.in_progress!
      redirect_to admin_event_participant_path(current_event, @participant_event),
        notice: "#{@participant_event.participant.display_name} has been reinstated."
    end

    def destroy
      authorize @participant_event
      participant_name = @participant_event.participant.display_name
      @participant_event.destroy!
      redirect_to admin_event_participants_path(current_event), notice: "#{participant_name} has been removed from this event."
    end

    # Tool for merging two Participant rows that belong to the same human —
    # e.g. someone who registered twice under different email addresses, so
    # their Slack link and completed registration sit on separate rows and
    # per-participant flows (channel invites) silently skip them.
    def merge
      authorize @participant_event, :merge_duplicate?

      @query = params[:q].to_s.strip
      if @query.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
        @candidates = Participant
          .where.not(id: @participant.id)
          .where(
            "legal_first_name ILIKE :term OR legal_last_name ILIKE :term OR " \
            "preferred_name ILIKE :term OR email ILIKE :term OR " \
            "CONCAT(legal_first_name, ' ', legal_last_name) ILIKE :term",
            term: term
          )
          .includes(:user, participant_events: :event)
          .order(:legal_last_name, :legal_first_name)
          .limit(20)
      end

      if params[:duplicate_id].present?
        @duplicate = Participant.where.not(id: @participant.id).find(params[:duplicate_id])
        @merge_preview = ParticipantMergeService.new(primary: @participant, duplicate: @duplicate).preview
      end
    end

    def merge_duplicate
      authorize @participant_event, :merge_duplicate?

      participant = @participant_event.participant
      duplicate = Participant.where.not(id: participant.id).find(params[:duplicate_id])
      duplicate_label = "#{duplicate.display_name} (#{duplicate.email})"

      @record = participant # audit-log against the surviving record
      actions = ParticipantMergeService.new(primary: participant, duplicate: duplicate).merge!

      summary = actions.any? ? actions.join("; ") : "nothing to transfer, deleted the duplicate record"
      redirect_to admin_event_participant_path(current_event, @participant_event),
        notice: "Merged #{duplicate_label} into this record: #{summary}."
    rescue ActiveRecord::RecordInvalid, ParticipantMergeService::Error => e
      redirect_to merge_admin_event_participant_path(current_event, @participant_event),
        alert: "Merge failed — nothing was changed: #{e.message}"
    end

    def resend_guardian_invite
      authorize @participant_event, :manage_guardians?

      if current_event.guardian_invites_locked?
        redirect_to admin_event_participant_path(current_event, @participant_event), alert: "Guardian invites are currently locked for this event."
        return
      end

      gpe = @participant_event.guardian_participant_events.find(params[:guardian_participant_event_id])
      gpe.update!(invite_token_sent_at: nil)

      GuardianMailer.invitation(guardian_participant_event: gpe).deliver_later
      redirect_to admin_event_participant_path(current_event, @participant_event), notice: "Guardian invite resent to #{gpe.guardian.email}."
    end

    def update_groups
      authorize @participant_event, :update?
      raise ActionController::RoutingError, "Not Found" unless current_event.groups_enabled?

      group_ids = Array(params[:group_ids]).reject(&:blank?)
      valid_ids = current_event.groups.where(id: group_ids).pluck(:id)

      ActiveRecord::Base.transaction do
        existing = @participant_event.group_memberships.pluck(:group_id)
        to_add = valid_ids - existing
        to_remove = existing - valid_ids

        @participant_event.group_memberships.where(group_id: to_remove).destroy_all
        to_add.each { |gid| @participant_event.group_memberships.create!(group_id: gid) }
      end

      redirect_to admin_event_participant_path(current_event, @participant_event),
        notice: "Groups updated."
    end

    def new_invite
      @invite = Struct.new(:email, :name, :group_ids).new("", "", [])
    end

    def send_invite
      email = params[:invite][:email]&.strip&.downcase
      name = params[:invite][:name]
      group_ids = Array(params[:invite][:group_ids]).reject(&:blank?)

      if email.blank?
        redirect_to new_invite_admin_event_participants_path(current_event), alert: "Email is required."
        return
      end

      if Ban.banned?(email)
        redirect_to new_invite_admin_event_participants_path(current_event), alert: "#{email} is banned from events and cannot be invited."
        return
      end

      begin
        ParticipantMailer.invitation(
          email: email,
          name: name,
          event: current_event,
          group_ids: group_ids
        ).deliver_later
        redirect_to admin_event_participants_path(current_event), notice: "Invitation sent to #{email}."
      rescue ActiveRecord::RecordInvalid => e
        redirect_to new_invite_admin_event_participants_path(current_event), alert: e.record.errors.full_messages.join(", ")
      rescue ArgumentError => e
        redirect_to new_invite_admin_event_participants_path(current_event), alert: e.message
      end
    end

    def revoke_invite
      invitation = current_event.invitations.find(params[:id])
      email = invitation.email
      invitation.destroy!
      redirect_to admin_event_participants_path(current_event, status: "pending_invitations"),
        notice: "Invitation for #{email} has been revoked."
    end

    def slack_invite_link
      authorize @participant_event, :update?

      unless @participant_event.complete?
        redirect_to admin_event_participant_path(current_event, @participant_event),
          alert: "Participant must complete onboarding before linking Slack."
        return
      end

      slack_service = SlackService.new
      @invite_url = slack_service.authorization_url(
        participant_event_id: @participant_event.id,
        redirect_uri: slack_oauth_callback_url
      )
    end

    def invite_to_slack_channel
      authorize @participant_event, :update?

      participant = @participant_event.participant

      participant.user&.sync_slack_id_to_participant if params[:prefill]

      unless participant.slack_user_id.present?
        redirect_to admin_event_participant_path(current_event, @participant_event),
          alert: "Participant must link their Slack account first."
        return
      end

      unless current_event.slack_channel_id.present?
        redirect_to admin_event_participant_path(current_event, @participant_event),
          alert: "No Slack channel configured for this event."
        return
      end

      begin
        slack_service = SlackService.new
        result = slack_service.invite_to_channel(
          channel_id: current_event.slack_channel_id,
          user_id: participant.slack_user_id
        )

        if result[:already_member]
          redirect_to admin_event_participant_path(current_event, @participant_event),
            notice: "#{@participant_event.participant.display_name} is already in the Slack channel."
        else
          redirect_to admin_event_participant_path(current_event, @participant_event),
            notice: "#{@participant_event.participant.display_name} has been added to the Slack channel."
        end
      rescue SlackService::Error => e
        error_message = if e.message.include?("channel_not_found")
          "We couldn't find that Slack channel. Either it doesn't exist, or you haven't invited the Hack Club Attend bot to it yet — you can do this through Slack's channel settings."
        else
          "Failed to invite to Slack channel: #{e.message}"
        end

        redirect_to admin_event_participant_path(current_event, @participant_event), alert: error_message
      end
    end

    def sync_slack_channel_preview
      authorize ParticipantEvent, :index?

      unless current_event.slack_channel_id.present?
        render json: { error: "No Slack channel configured for this event." }, status: :unprocessable_entity
        return
      end

      completed_participants = current_event.participant_events.complete
      with_slack = completed_participants.joins(:participant).where.not(participants: { slack_user_id: [ nil, "" ] })
      without_slack = completed_participants.joins(:participant).where(participants: { slack_user_id: [ nil, "" ] })

      last_sync = current_event.last_slack_sync_at
      last_sync_text = if last_sync.nil?
        "never"
      else
        helpers.time_ago_in_words(last_sync) + " ago"
      end

      render json: {
        slack_invite_count: with_slack.count,
        email_count: without_slack.count,
        last_sync: last_sync_text
      }
    end

    def sync_slack_channel
      authorize ParticipantEvent, :index?

      unless current_event.slack_channel_id.present?
        redirect_to admin_event_participants_path(current_event),
          alert: "No Slack channel configured for this event."
        return
      end

      # One Slack API call per participant — far too slow to run in-request
      # for large events. The job broadcasts progress on SlackSyncChannel.
      SyncSlackChannelJob.perform_later(current_event.id, send_emails: params[:send_emails] == "1")

      @record = current_event # audit-log who kicked off the sync

      redirect_to admin_event_participants_path(current_event),
        notice: "Slack sync started — progress will appear on this page."
    end

    private

    def set_participant_event
      @participant_event = current_event.participant_events.find(params[:id])
    end

    def set_participant_header_data
      @participant = @participant_event.participant
      @safeguarding_info = @participant_event.safeguarding_info
      @notes = @participant_event.notes.includes(:author).order(created_at: :desc)
    end

    def participant_params
      params.require(:participant).permit(
        :legal_first_name, :legal_last_name, :preferred_name, :email,
        :date_of_birth, :phone, :pronouns, :tshirt_size, :headshot
      )
    end

    def travel_params(direction)
      key = "travel_#{direction}"
      return { direction: direction } unless params[key].present?

      permitted = params.require(key).permit(
        :mode, :carrier, :flight_number, :departure_city, :departure_time,
        :arrival_city, :arrival_time, :arrival_location, :booking_reference,
        :visa_status, :visa_notes, :is_unaccompanied_minor, :notes,
        :train_departure_station, :train_arrival_station,
        :bus_departure_location, :bus_arrival_location,
        :origin_address, :expected_arrival_time, :other_details,
        travel_legs_attributes: [ :id, :position, :flight_code, :departure_airport, :arrival_airport,
                                 :departure_time, :departure_time_zone, :arrival_time, :arrival_time_zone, :confirmation_code, :_destroy ]
      ).merge(direction: direction)

      normalize_leg_times!(permitted)
      permitted
    end

    def accommodation_params
      params.require(:accommodation).permit(
        :check_in_date, :check_out_date, :gender_identity, :gender_identity_other, :gender_base, :is_transgender,
        :roommate_preferences, :roommate_exclusions, :accessibility_needs, :assigned_room, :notes, :rooming_exempt,
        preferred_roommate_genders: []
      )
    end

    def medical_params
      params.fetch(:medical, {}).permit(
        :allergies, :has_anaphylaxis_risk, :medical_conditions, :medications,
        :requires_refrigeration, :emergency_action_plan, :additional_notes
      )
    end

    def dietary_params
      params.fetch(:dietary, {}).permit(
        :diet_type, :cross_contamination_risk, :intolerances,
        :life_threatening_allergies, :notes
      )
    end

    def accessibility_params
      params.fetch(:accessibility, {}).permit(
        :has_adhd, :has_dyslexia, :has_autism, :neurodivergent_notes,
        :uses_wheelchair, :step_free_required, :needs_captioning,
        :needs_large_print, :needs_sign_language, :other_needs,
        :mobility_needs, :sensory_needs, :communication_needs,
        :light_sensitivity, :noise_sensitivity, :strobe_sensitivity,
        :prayer_space_required, :requires_private_space, :religious_practices,
        :distance_limitations, :unavailable_times
      )
    end

    def safeguarding_params
      params.require(:safeguarding_info).permit(
        :high_support_flag, :high_support_notes, :freedom_waiver_granted,
        :can_leave_unaccompanied, :authorized_pickup_adults, :other_instructions
      )
    end

    def can_access_medical?
      return true if current_user.global_admin?

      role = current_user.role_for_event(current_event)
      %w[event_admin ops safeguarding_lead].include?(role)
    end

    def require_safeguarding_access
      return if current_user.global_admin?

      role = current_user.role_for_event(current_event)
      unless %w[safeguarding_lead event_admin].include?(role)
        redirect_to admin_event_participant_path(current_event, @participant_event),
          alert: "Only safeguarding leads and event admins can access this information."
      end
    end

    def apply_table_filters(scope)
      return scope unless params[:filters].present?

      filters = parse_filters(params[:filters])
      filter_logic = params[:filter_logic] || "and"

      if filter_logic == "or"
        apply_or_filters(scope, filters)
      else
        apply_and_filters(scope, filters)
      end
    end

    def parse_filters(raw_filters)
      return [] if raw_filters.blank?

      if raw_filters.is_a?(ActionController::Parameters) || raw_filters.is_a?(Hash)
        raw_filters.to_unsafe_h.values.map do |f|
          { field: f["field"], operator: f["operator"], value: f["value"] }
        end
      else
        raw_filters.map do |f|
          { field: f["field"], operator: f["operator"], value: f["value"] }
        end
      end
    end

    def apply_and_filters(scope, filters)
      filters.each do |filter|
        next if filter[:field].blank? || filter[:value].blank?

        scope = apply_single_filter(scope, filter[:field], filter[:operator], filter[:value])
      end
      scope
    end

    def apply_or_filters(scope, filters)
      valid_filters = filters.select { |f| f[:field].present? && f[:value].present? }

      return scope if valid_filters.empty?

      # Strip render-only includes before plucking: a filter with a raw-SQL
      # where referencing an included table would force eager_load of every
      # association, including the headshot attachment join that breaks on
      # varchar record_id = uuid participants.id.
      bare_scope = scope.except(:includes, :preload, :eager_load)
      ids = valid_filters.flat_map do |filter|
        apply_single_filter(bare_scope, filter[:field], filter[:operator], filter[:value]).pluck(:id)
      end.uniq

      scope.where(id: ids)
    end

    def apply_single_filter(scope, field, operator, value)
      case field
      when "status"
        apply_status_filter(scope, operator, value)
      when "legal_first_name", "legal_last_name", "preferred_name", "email", "pronouns"
        apply_participant_text_filter(scope, field, operator, value)
      when "age"
        apply_age_filter(scope, operator, value)
      when "tshirt_size"
        apply_participant_field_filter(scope, field, operator, value)
      when "travel_mode"
        apply_travel_mode_filter(scope, operator, value)
      when "has_anaphylaxis"
        apply_boolean_filter(scope, :medical, :has_anaphylaxis_risk, operator, value)
      when "high_support"
        apply_boolean_filter(scope, :safeguarding_info, :high_support_flag, operator, value)
      when "is_minor"
        apply_minor_filter(scope, operator, value)
      when "onboarding_complete"
        apply_onboarding_filter(scope, operator, value)
      when "waiver_signed"
        apply_waiver_filter(scope, operator, value)
      when "freedom_waiver_granted"
        apply_freedom_waiver_filter(scope, operator, value)
      when "scan_context"
        apply_scan_context_filter(scope, operator, value)
      when "group"
        apply_group_filter(scope, operator, value)
      else
        scope
      end
    end

    def apply_group_filter(scope, operator, value)
      return scope unless current_event.groups_enabled?

      group_ids = Array(value).reject(&:blank?)
      member_ids = GroupMembership.where(group_id: group_ids).select(:participant_event_id)

      case operator
      when "is", "is_any"
        scope.where(id: member_ids)
      when "is_not"
        scope.where.not(id: member_ids)
      when "is_empty"
        scope.where.not(id: GroupMembership.select(:participant_event_id))
      when "is_not_empty"
        scope.where(id: GroupMembership.select(:participant_event_id))
      else
        scope
      end
    end

    DISPLAY_STATUS_TO_DB = {
      "awaiting_participant" => %w[invited in_progress],
      "awaiting_parent"     => %w[awaiting_guardian],
      "complete"            => %w[complete],
      "withdrawn"           => %w[withdrawn],
      "rejected"            => %w[rejected]
    }.freeze

    def apply_status_filter(scope, operator, value)
      db_statuses = DISPLAY_STATUS_TO_DB[value] || [ value ]
      case operator
      when "is"
        scope.where(status: db_statuses)
      when "is_not"
        scope.where.not(status: db_statuses)
      else
        scope
      end
    end

    ALLOWED_PARTICIPANT_TEXT_FIELDS = %w[legal_first_name legal_last_name preferred_name email pronouns].freeze

    def apply_participant_text_filter(scope, field, operator, value)
      return scope unless ALLOWED_PARTICIPANT_TEXT_FIELDS.include?(field)

      table = Participant.arel_table
      column = table[field.to_sym]

      case operator
      when "contains"
        scope.joins(:participant).where(column.matches("%#{ActiveRecord::Base.sanitize_sql_like(value)}%"))
      when "equals"
        scope.joins(:participant).where(column.matches(ActiveRecord::Base.sanitize_sql_like(value)))
      when "starts_with"
        scope.joins(:participant).where(column.matches("#{ActiveRecord::Base.sanitize_sql_like(value)}%"))
      when "is_empty"
        scope.joins(:participant).where(column.eq(nil).or(column.eq("")))
      when "is_not_empty"
        scope.joins(:participant).where(column.not_eq(nil).and(column.not_eq("")))
      else
        scope
      end
    end

    ALLOWED_PARTICIPANT_FILTER_FIELDS = %w[tshirt_size].freeze

    def apply_participant_field_filter(scope, field, operator, value)
      return scope unless ALLOWED_PARTICIPANT_FILTER_FIELDS.include?(field)

      table = Participant.arel_table
      column = table[field.to_sym]

      case operator
      when "is"
        scope.joins(:participant).where(column.eq(value))
      when "is_not"
        scope.joins(:participant).where(column.not_eq(value).or(column.eq(nil)))
      else
        scope
      end
    end

    def apply_age_filter(scope, operator, value)
      event_date = current_event.starts_at&.to_date || Date.current
      birth_date = event_date - value.to_i.years

      case operator
      when "equals"
        scope.joins(:participant).where("participants.date_of_birth BETWEEN ? AND ?", birth_date - 1.year + 1.day, birth_date)
      when "greater_than"
        scope.joins(:participant).where("participants.date_of_birth < ?", birth_date)
      when "less_than"
        scope.joins(:participant).where("participants.date_of_birth > ?", birth_date)
      else
        scope
      end
    end

    def apply_travel_mode_filter(scope, operator, value)
      case operator
      when "is"
        scope.joins(:travel_inbound).where(travels: { mode: value })
      when "is_not"
        scope.joins(:travel_inbound).where.not(travels: { mode: value })
      else
        scope
      end
    end

    def apply_boolean_filter(scope, relation, field, operator, value)
      bool_value = value == "true"
      case operator
      when "is"
        scope.joins(relation).where(relation.to_s.pluralize => { field => bool_value })
      when "is_not"
        scope.joins(relation).where.not(relation.to_s.pluralize => { field => bool_value })
      else
        scope
      end
    end

    def apply_minor_filter(scope, operator, value)
      event_date = current_event.starts_at&.to_date || Date.current
      adult_birth_date = event_date - 18.years
      is_minor = value == "true"

      case operator
      when "is"
        if is_minor
          scope.joins(:participant).where("participants.date_of_birth > ?", adult_birth_date)
        else
          scope.joins(:participant).where("participants.date_of_birth <= ?", adult_birth_date)
        end
      else
        scope
      end
    end

    def apply_onboarding_filter(scope, operator, value)
      complete = value == "true"
      incomplete = current_event.participant_events.missing_onboarding_data(accommodation_required: current_event.accommodation_enabled?)

      if complete
        scope.where.not(id: incomplete.select(:id))
      else
        scope.merge(incomplete)
      end
    end

    def apply_waiver_filter(scope, operator, value)
      signed = value == "true"
      signed_waivers = Consent.where(consent_type: "waiver", status: "signed").select(:participant_event_id)
      if signed
        scope.where(id: signed_waivers)
      else
        scope.where.not(id: signed_waivers)
      end
    end

    def apply_freedom_waiver_filter(scope, operator, value)
      granted = value == "true"
      granted_infos = SafeguardingInfo.where(freedom_waiver_granted: true).select(:participant_event_id)
      if granted
        scope.where(id: granted_infos)
      else
        scope.where.not(id: granted_infos)
      end
    end

    def apply_scan_context_filter(scope, operator, value)
      scan_context = current_event.scan_contexts.find_by(id: value)
      return scope unless scan_context

      scanned_ids = Scan.for_context(scan_context)
        .select(:participant_event_id).distinct

      case operator
      when "scanned_in"
        scope.where(id: scanned_ids)
      when "not_scanned_in"
        scope.where.not(id: scanned_ids)
      else
        scope
      end
    end

    ALLOWED_PARTICIPANT_SORT_FIELDS = %w[legal_first_name legal_last_name preferred_name email date_of_birth tshirt_size pronouns].freeze

    ARRIVAL_SUBQUERY = <<~SQL.squish.freeze
      (SELECT COALESCE(
        (SELECT MAX(tl.arrival_time) FROM travel_legs tl
         JOIN travels t ON t.id = tl.travel_id
         WHERE t.participant_event_id = participant_events.id AND t.direction = 'inbound'),
        (SELECT t.arrival_time FROM travels t
         WHERE t.participant_event_id = participant_events.id AND t.direction = 'inbound')
      ))
    SQL

    DEPARTURE_SUBQUERY = <<~SQL.squish.freeze
      (SELECT COALESCE(
        (SELECT MIN(tl.departure_time) FROM travel_legs tl
         JOIN travels t ON t.id = tl.travel_id
         WHERE t.participant_event_id = participant_events.id AND t.direction = 'outbound'),
        (SELECT t.departure_time FROM travels t
         WHERE t.participant_event_id = participant_events.id AND t.direction = 'outbound')
      ))
    SQL

    def apply_table_sorting(scope)
      direction = @sort_direction == "desc" ? :desc : :asc
      nulls_last = direction == :desc ? "DESC NULLS LAST" : "ASC NULLS LAST"

      case @sort_field
      when *ALLOWED_PARTICIPANT_SORT_FIELDS
        table = Participant.arel_table
        scope.joins(:participant).order(table[@sort_field.to_sym].send(direction))
      when "status"
        scope.order(status: direction)
      when "created_at"
        scope.order(created_at: direction)
      when "gender_identity"
        scope.left_joins(:accommodation).order(Arel.sql("accommodations.gender_identity #{nulls_last}"))
      when "group"
        scope.left_joins(group_memberships: :group).order(Arel.sql("groups.position #{nulls_last}, groups.name #{nulls_last}"))
      when "arrival_time"
        scope.order(Arel.sql("#{ARRIVAL_SUBQUERY} #{nulls_last}"))
      when "departure_time"
        scope.order(Arel.sql("#{DEPARTURE_SUBQUERY} #{nulls_last}"))
      else
        scope.joins(:participant).order(Participant.arel_table[:legal_last_name].send(direction))
      end
    end

    def group_participants(scope)
      case @group_by
      when "status"
        scope.group_by(&:display_status)
      when "travel_mode"
        scope.group_by { |pe| pe.travel_inbound&.mode || "Not set" }
      when "tshirt_size"
        scope.group_by { |pe| pe.participant.tshirt_size || "Not set" }
      when "is_minor"
        event_date = current_event.starts_at&.to_date || Date.current
        scope.group_by { |pe| pe.participant.minor_on?(event_date) ? "Minor" : "Adult" }
      when "onboarding_complete"
        scope.group_by { |pe| pe.onboarding_complete? ? "Complete" : "Incomplete" }
      when "waiver_signed"
        scope.group_by { |pe| pe.waiver_signed? ? "Signed" : "Not Signed" }
      when "freedom_waiver_granted"
        scope.group_by { |pe| pe.safeguarding_info&.freedom_waiver_granted? ? "Granted" : "Not Granted" }
      when "has_anaphylaxis"
        scope.group_by { |pe| pe.medical&.has_anaphylaxis_risk ? "Yes" : "No" }
      when "high_support"
        scope.group_by { |pe| pe.safeguarding_info&.high_support? ? "Yes" : "No" }
      when "diet_type"
        scope.group_by { |pe| pe.dietary&.diet_type&.titleize || "Not set" }
      when "group"
        scope.flat_map { |pe| pe.groups.any? ? pe.groups.map { |g| [ g.name, pe ] } : [ [ "Ungrouped", pe ] ] }
             .group_by(&:first)
             .transform_values { |pairs| pairs.map(&:last) }
      else
        { "All Participants" => scope.to_a }
      end
    end

    def send_waiver_reset_email(waiver_type:)
      if @participant_event.requires_guardian?
        guardian_participant_event = @participant_event.guardian_participant_events.first
        return unless guardian_participant_event

        GuardianMailer.waiver_reset(
          guardian_participant_event: guardian_participant_event,
          waiver_type: waiver_type
        ).deliver_later
      else
        ParticipantMailer.waiver_ready(participant_event: @participant_event).deliver_later
      end
    end

    def reopen_guardian_portal_access
      return unless @participant_event.requires_guardian?

      @participant_event.guardian_participant_events.each do |gpe|
        gpe.update!(status: :in_progress) if gpe.completed?
      end
    end
  end
end
