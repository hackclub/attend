module Api
  module V1
    class ParticipantsController < BaseController
      include Pundit::Authorization

      # Roles without participant API access (read_only, limited) would
      # otherwise surface Pundit's exception as a 500 to the mobile app.
      rescue_from Pundit::NotAuthorizedError do
        render json: { error: "Forbidden" }, status: :forbidden
      end

      before_action :restrict_api_key_actions
      before_action :set_event
      before_action :set_participant_event, only: [ :show ]

      def index
        sync_cutoff = Time.current
        participant_events = @event.participant_events
          .includes(
            :event,
            :medical,
            :dietary,
            :safeguarding_info,
            :consents,
            participant: { headshot_attachment: :blob },
            guardian_participant_events: [ :guardian, :emergency_contacts ],
            travel_inbound: :travel_legs,
            travel_outbound: :travel_legs,
            scans: :scan_context
          )
          .where("participant_events.updated_at <= ?", sync_cutoff)

        if params[:updated_since].present?
          since = Time.zone.parse(params[:updated_since])
          participant_events = participant_events.where("participant_events.updated_at > ?", since)
        end

        render json: {
          participants: participant_events.map { |pe| participant_json(pe) },
          synced_at: sync_cutoff.iso8601(6)
        }
      end

      def show
        render json: {
          participant: participant_json(@participant_event, detailed: true)
        }
      end

      def search
        query = params[:q].to_s.strip
        return render json: { results: [] } if query.blank?

        sanitized_like = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
        participant_events = @event.participant_events
          .joins(:participant)
          .includes(:participant, :medical, :dietary, :safeguarding_info, scans: :scan_context)
          .where(
            "LOWER(participants.legal_first_name) LIKE :q OR " \
            "LOWER(participants.legal_last_name) LIKE :q OR " \
            "LOWER(participants.preferred_name) LIKE :q OR " \
            "LOWER(participants.email) LIKE :q OR " \
            "LOWER(CAST(participants.id AS TEXT)) LIKE :q",
            q: sanitized_like
          )
          .limit(20)

        render json: {
          results: participant_events.map { |pe| participant_json(pe) }
        }
      end

      def create
        email = params[:email]&.strip&.downcase
        first_name = params[:first_name]&.strip
        last_name = params[:last_name]&.strip
        name = [ first_name, last_name ].compact.join(" ").presence

        if email.blank?
          return render json: { success: false, error: "Email is required" }, status: :unprocessable_entity
        end

        unless email.match?(URI::MailTo::EMAIL_REGEXP)
          return render json: { success: false, error: "Invalid email format" }, status: :unprocessable_entity
        end

        if Ban.banned?(email)
          return render json: { success: false, error: "This email is banned from events" }, status: :unprocessable_entity
        end

        existing_invitation = @event.invitations.find_by(email: email)
        if existing_invitation
          return render json: { success: false, error: "An invitation has already been sent to this email" }, status: :conflict
        end

        existing_participant = @event.participants.find_by(email: email)
        if existing_participant
          return render json: { success: false, error: "This email is already registered for this event" }, status: :conflict
        end

        begin
          ParticipantMailer.invitation(
            email: email,
            name: name,
            event: @event
          ).deliver_later

          render json: {
            success: true,
            message: "Invitation sent to #{email}",
            event: @event.name
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { success: false, error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      # Read-only participation check. Unlike `create`, this never sends an
      # invitation or mutates anything, so it is safe to call on every sign-in.
      def lookup
        email = params[:email].to_s.strip.downcase

        if email.blank?
          return render json: { error: "Email is required" }, status: :unprocessable_entity
        end

        participant = @event.participants.find_by(email: email)
        participant_event = participant && @event.participant_events.find_by(participant_id: participant.id)

        render json: {
          email: email,
          registered: participant_event.present?,
          participant_id: participant&.id,
          status: participant_event&.status
        }
      end

      # Minimal roster for external integrations: just enough to build an
      # allowlist (email and name), excluding withdrawn/rejected registrations.
      # Unlike `index`, this exposes none of the sensitive
      # medical/safeguarding/travel data, so event API keys may call it.
      def roster
        participant_events = @event.participant_events
          .where.not(status: [ :withdrawn, :rejected ])
          .includes(:participant)

        render json: {
          participants: participant_events.map { |pe|
            participant = pe.participant
            {
              email: participant.email,
              # Mirror Participant#display_name: preferred name wins when set.
              first_name: participant.preferred_name.presence || participant.legal_first_name,
              last_name: participant.legal_last_name,
              slack_user_id: participant.slack_user_id,
              status: pe.status
            }
          },
          synced_at: Time.current.iso8601
        }
      end

      private

      # An API key may only send invitations and read minimal
      # identity/registration data (lookup, roster) — never the full
      # participant payload from index/show, which includes sensitive
      # medical/safeguarding/travel PII. Applies to event and series keys
      # alike: a series key is broader in reach, not in what it may read.
      API_KEY_ALLOWED_ACTIONS = %w[create lookup roster].freeze

      def restrict_api_key_actions
        return unless api_key_request?
        return if API_KEY_ALLOWED_ACTIONS.include?(action_name)

        render json: { error: "API key is not authorized for this action" }, status: :forbidden
      end

      def set_event
        @event = Event.find_by(id: params[:event_id]) || Event.find_by!(slug: params[:event_id])
        Current.event = @event

        if api_key_request?
          require_api_key_event_scope!(@event)
        else
          authorize @event, :api_participants?
        end
      end

      def set_participant_event
        @participant_event = @event.participant_events
          .includes(
            :participant,
            :event,
            :medical,
            :dietary,
            :accessibility,
            :accommodation,
            :safeguarding_info,
            :consents,
            guardian_participant_events: [ :guardian, :emergency_contacts ],
            travel_inbound: :travel_legs,
            travel_outbound: :travel_legs,
            scans: :scan_context
          )
          .find(params[:id])
      end

      def participant_json(pe, detailed: false)
        participant = pe.participant
        medical = pe.medical
        dietary = pe.dietary
        safeguarding = pe.safeguarding_info

        data = {
          participant_id: participant.id,
          participant_event_id: pe.id,
          display_name: participant.display_name,
          full_name: participant.full_name,
          email: participant.email,
          # The phone is omitted, not nulled, for PII-restricted roles — same
          # contract as date_of_birth and address in #personal_json.
          **(include_pii? ? { phone: participant.phone } : {}),
          slack_user_id: participant.slack_user_id,
          pronouns: participant.pronouns,
          headshot_url: headshot_url_for(participant),
          status: pe.status,
          checked_in_at: pe.check_in_time&.iso8601,
          nfc_badge_token: pe.event.nfc_badges_enabled? ? pe.nfc_badge_token : nil,
          nfc_badge_assigned: pe.nfc_badge_assigned?,

          has_anaphylaxis_risk: medical&.has_anaphylaxis_risk || false,
          requires_refrigeration: medical&.requires_refrigeration || false,
          cross_contamination_risk: dietary&.cross_contamination_risk || false,
          high_support_flag: safeguarding&.high_support_flag || false,
          can_leave_unaccompanied: safeguarding&.can_leave_unaccompanied || false,

          waiver_signed: pe.waiver_signed?,
          updated_at: pe.updated_at.iso8601
        }

        if can_view_sensitive_data?
          data.merge!(
            allergies: medical&.allergies,
            medical_conditions: medical&.medical_conditions,
            medications: medical&.medications,
            diet_type: dietary&.diet_type,
            life_threatening_allergies: dietary&.life_threatening_allergies,
            freedom_waiver_granted: safeguarding&.freedom_waiver_granted || false,
            emergency_contacts: emergency_contacts_json(pe)
          )

          # Add primary guardian contact info
          primary_guardian = pe.guardian_participant_events.first&.guardian
          if primary_guardian
            data.merge!(
              parent_guardian_name: primary_guardian.full_name,
              parent_guardian_phone: primary_guardian.phone,
              parent_guardian_email: primary_guardian.email
            )
          end
        end

        data[:travel_inbound] = travel_json(pe.travel_inbound) if pe.travel_inbound
        data[:travel_outbound] = travel_json(pe.travel_outbound) if pe.travel_outbound

        data[:scans_by_context] = scans_by_context_json(pe)

        if detailed
          data.merge!(detailed_participant_fields(pe))
        end

        data
      end

      def detailed_participant_fields(pe)
        participant = pe.participant
        medical = pe.medical
        dietary = pe.dietary
        accessibility = pe.accessibility
        accommodation = pe.accommodation
        safeguarding = pe.safeguarding_info

        extra = {
          personal: personal_json(participant),
          accommodation: accommodation_json(accommodation),
          consents: pe.consents.map { |c| consent_json(c) },
          guardians: pe.guardian_participant_events.map { |gpe| guardian_json(gpe) }
        }

        if can_view_sensitive_data?
          extra[:medical_detail] = medical_detail_json(medical)
          extra[:dietary_detail] = dietary_detail_json(dietary)
          extra[:accessibility] = accessibility_json(accessibility)
          extra[:safeguarding_detail] = safeguarding_detail_json(safeguarding)
        end

        extra
      end

      # `age` is always present; `date_of_birth` and `address` are omitted
      # entirely for PII-restricted roles rather than sent as null, so a client
      # can tell "not permitted" from "not on file".
      def personal_json(participant)
        base = {
          legal_first_name: participant.legal_first_name,
          legal_last_name: participant.legal_last_name,
          preferred_name: participant.preferred_name,
          age: participant.date_of_birth ? age_from(participant.date_of_birth) : nil,
          tshirt_size: participant.tshirt_size,
          engagement_preference: participant.engagement_preference,
          engagement_notes: participant.engagement_notes
        }
        return base unless include_pii?

        base.merge(
          date_of_birth: participant.date_of_birth&.iso8601,
          address: {
            line_1: participant.address_line_1,
            line_2: participant.address_line_2,
            city: participant.city,
            state: participant.state,
            postal_code: participant.postal_code,
            country: participant.country_of_residence
          }.compact_blank
        )
      end

      def age_from(dob)
        today = Date.current
        age = today.year - dob.year
        age -= 1 if today < dob + age.years
        age
      end

      def accommodation_json(acc)
        return nil unless acc
        {
          check_in_date: acc.check_in_date&.iso8601,
          check_out_date: acc.check_out_date&.iso8601,
          gender_identity: acc.gender_identity,
          gender_identity_other: acc.gender_identity_other,
          assigned_room: acc.assigned_room,
          rooming_exempt: acc.rooming_exempt,
          venue_name: acc.venue_name,
          preferred_roommate_genders: acc.preferred_roommate_genders,
          roommate_preferences: acc.roommate_preferences,
          roommate_exclusions: acc.roommate_exclusions,
          quiet_room_preference: acc.quiet_room_preference,
          room_type_preference: acc.room_type_preference,
          accessibility_needs: acc.accessibility_needs,
          notes: acc.notes
        }
      end

      def medical_detail_json(med)
        return nil unless med
        {
          allergy_severity: med.allergy_severity,
          emergency_action_plan: med.emergency_action_plan,
          additional_notes: med.additional_notes
        }
      end

      def dietary_detail_json(diet)
        return nil unless diet
        {
          intolerances: diet.intolerances,
          notes: diet.notes
        }
      end

      def accessibility_json(acc)
        return nil unless acc
        {
          mobility_needs: acc.mobility_needs,
          uses_wheelchair: acc.uses_wheelchair,
          step_free_required: acc.step_free_required,
          sensory_needs: acc.sensory_needs,
          light_sensitivity: acc.light_sensitivity,
          noise_sensitivity: acc.noise_sensitivity,
          strobe_sensitivity: acc.strobe_sensitivity,
          communication_needs: acc.communication_needs,
          needs_captioning: acc.needs_captioning,
          needs_large_print: acc.needs_large_print,
          needs_sign_language: acc.needs_sign_language,
          neurodivergent_notes: acc.neurodivergent_notes,
          has_adhd: acc.has_adhd,
          has_autism: acc.has_autism,
          has_dyslexia: acc.has_dyslexia,
          religious_practices: acc.religious_practices,
          prayer_space_required: acc.prayer_space_required,
          requires_private_space: acc.requires_private_space,
          distance_limitations: acc.distance_limitations,
          unavailable_times: acc.unavailable_times,
          other_needs: acc.other_needs
        }
      end

      def safeguarding_detail_json(sg)
        return nil unless sg
        {
          high_support_notes: sg.high_support_notes,
          authorized_pickup_adults: sg.authorized_pickup_adults,
          other_instructions: sg.other_instructions
        }
      end

      def consent_json(consent)
        {
          id: consent.id,
          consent_type: consent.consent_type,
          status: consent.status,
          pending_on: consent.pending_on,
          sent_at: consent.sent_at&.iso8601,
          viewed_at: consent.respond_to?(:viewed_at) ? consent.viewed_at&.iso8601 : nil,
          participant_signed_at: consent.participant_signed_at&.iso8601,
          guardian_signed_at: consent.guardian_signed_at&.iso8601,
          signed_at: consent.signed_at&.iso8601,
          document_url: consent.document_url,
          failure_reason: consent.failure_reason
        }
      end

      def guardian_json(gpe)
        g = gpe.guardian
        {
          id: gpe.id,
          guardian_id: g&.id,
          name: g&.full_name,
          **(include_pii? ? { email: g&.email, phone: gpe.phone_override.presence || g&.phone } : {}),
          relationship: gpe.relationship,
          is_primary: gpe.is_primary_guardian,
          status: gpe.status,
          accepted_at: gpe.accepted_at&.iso8601,
          completed_at: gpe.completed_at&.iso8601,
          **(include_pii? ? { invited_via_email: gpe.invited_via_email } : {}),
          invite_token_sent_at: gpe.invite_token_sent_at&.iso8601,
          media_permission: gpe.media_permission,
          photo_permission: gpe.photo_permission,
          travel_permission: gpe.travel_permission,
          emergency_medical_consent: gpe.emergency_medical_consent,
          otc_medication_consent: gpe.otc_medication_consent,
          emergency_contacts: gpe.emergency_contacts.by_priority.map { |ec| emergency_contact_json(ec) }
        }
      end

      # An emergency contact's phone number is the one number a PII-restricted
      # role keeps — you can't run an incident without being able to call
      # someone — but they get the first name only, and no email address.
      def emergency_contact_json(ec)
        return { id: ec.id, name: ec.first_name, phone: ec.phone, priority: ec.priority } unless include_pii?

        {
          id: ec.id,
          name: ec.name,
          phone: ec.phone,
          email: ec.email,
          relationship: ec.relationship,
          priority: ec.priority
        }
      end

      def scans_by_context_json(pe)
        scans = pe.scans.sort_by(&:scanned_at)
        scans.group_by(&:scan_context).map do |context, context_scans|
          next unless context
          {
            scan_context_id: context.id,
            scan_context_name: context.name,
            checks_in: context.checks_in,
            is_travel_pickup: context.is_travel_pickup,
            is_airport: context.is_travel_pickup,
            scan_count: context_scans.size,
            first_scanned_at: context_scans.first&.scanned_at&.iso8601,
            last_scanned_at: context_scans.last&.scanned_at&.iso8601
          }
        end.compact
      end

      def travel_json(travel)
        return nil unless travel

        {
          id: travel.id,
          direction: travel.direction,
          mode: travel.mode,
          visa_required: travel.visa_required,
          visa_status: travel.visa_status,
          visa_type: travel.visa_type,
          visa_number: travel.visa_number,
          passport_nationality: travel.passport_nationality,
          is_unaccompanied_minor: travel.is_unaccompanied_minor || false,
          carrier: travel.carrier,
          flight_number: travel.flight_number,
          train_departure_station: travel.train_departure_station,
          train_arrival_station: travel.train_arrival_station,
          departure_station: travel.departure_station,
          arrival_station: travel.arrival_station,
          departure_city: travel.departure_city,
          arrival_city: travel.arrival_city,
          departure_time: travel.departure_time&.iso8601,
          arrival_time: travel.arrival_time&.iso8601,
          expected_arrival_time: travel.expected_arrival_time&.iso8601,
          bus_departure_location: travel.bus_departure_location,
          bus_arrival_location: travel.bus_arrival_location,
          **(include_pii? ? { origin_address: travel.origin_address } : {}),
          other_details: travel.other_details,
          notes: travel.notes,
          pickup_dismissed_at: travel.pickup_dismissed_at&.iso8601,
          legs: travel.travel_legs.map { |leg| travel_leg_json(leg) }
        }
      end

      def travel_leg_json(leg)
        {
          id: leg.id,
          position: leg.position,
          flight_code: leg.flight_code,
          departure_airport: leg.departure_airport,
          arrival_airport: leg.arrival_airport,
          departure_time: leg.departure_time&.iso8601,
          arrival_time: leg.arrival_time&.iso8601,
          live_status: leg.live_status,
          live_departure_time: leg.live_departure_time&.iso8601,
          live_arrival_time: leg.live_arrival_time&.iso8601,
          travel_picked_up_at: leg.travel_picked_up_at&.iso8601,
          airport_picked_up_at: leg.travel_picked_up_at&.iso8601
        }
      end

      # Whether this caller gets exact dates of birth, addresses, phone numbers,
      # and the people around a participant (guardian and emergency contact
      # details). A participant's own email address is not gated. Memoized
      # for the same reason as can_view_sensitive_data? below. A nil
      # current_user means an event API key, which never reaches the actions
      # that serve these fields (see API_KEY_ALLOWED_ACTIONS).
      def include_pii?
        return @include_pii if defined?(@include_pii)

        @include_pii = current_user.nil? || current_user.can_view_participant_pii?(@event)
      end

      # Memoized per request: participant_json calls this once per participant,
      # and safeguarding_lead_for? is an EXISTS query. `defined?` guard because
      # the memoized value is usually false.
      def can_view_sensitive_data?
        return @can_view_sensitive_data if defined?(@can_view_sensitive_data)

        @can_view_sensitive_data =
          if current_user
            current_user.global_admin? || current_user.safeguarding_lead_for?(@event)
          else
            false
          end
      end

      def emergency_contacts_json(pe)
        pe.guardian_participant_events.flat_map do |gpe|
          gpe.emergency_contacts.sort_by { |ec| ec.priority || Float::INFINITY }.map do |ec|
            next { name: ec.first_name, phone: ec.phone, priority: ec.priority } unless include_pii?

            {
              name: ec.name,
              phone: ec.phone,
              relationship: ec.relationship,
              priority: ec.priority
            }
          end
        end
      end

      def default_url_host
        ENV.fetch("APP_HOST") { Rails.application.config.action_mailer.default_url_options[:host] || "localhost:3000" }
      end

      def headshot_url_for(participant)
        return nil unless participant.headshot.attached?

        host = request.host_with_port
        protocol = request.protocol
        path = Rails.application.routes.url_helpers.rails_storage_proxy_path(participant.headshot, only_path: true)
        "#{protocol}#{host}#{path}"
      rescue StandardError => e
        Rails.logger.error("Failed to generate headshot URL: #{e.message}")
        nil
      end
    end
  end
end
