require "csv"

module Airtable
  class SyncService
    PARTICIPANTS_TABLE = "Participants".freeze

    SYNC_COLUMNS = [
      "Participant Event ID",
      "Email",
      "First Name",
      "Last Name",
      "Preferred Name",
      "Pronouns",
      "Date of Birth",
      "Age at Event",
      "Is Minor",
      "Phone",
      "T-Shirt Size",
      "Country",
      "Status",
      "Checked In",
      "Checked In At",
      "Onboarding Complete",
      "Waiver Signed",
      "Slack User ID",
      "NFC Badge Assigned",
      "Inbound Travel Mode",
      "Inbound Departure City",
      "Inbound Arrival Time",
      "Inbound Flight Codes",
      "Inbound Visa Required",
      "Inbound Visa Status",
      "Outbound Travel Mode",
      "Outbound Departure City",
      "Outbound Departure Time",
      "Outbound Flight Codes",
      "Check-In Date",
      "Check-Out Date",
      "Gender Identity",
      "Room Name",
      "Diet Type",
      "Cross Contamination Risk",
      "Life Threatening Food Allergies",
      "Has Anaphylaxis Risk",
      "Has Allergies",
      "Requires Refrigeration",
      "Uses Wheelchair",
      "Step Free Required",
      "High Support",
      "Freedom Waiver Granted",
      "Can Leave Unaccompanied",
      "Guardian Name",
      "Guardian Email",
      "Guardian Phone",
      "Guardian Status",
      "Emergency Contact Name",
      "Emergency Contact Phone"
    ].freeze

    def initialize(event)
      @event = event
      @client = build_client
    end

    # --- Sync API (CSV-based full sync) ---

    def sync_via_api(table_id_or_name, sync_id)
      participant_events = load_participant_events
      csv = serialize_all_to_csv(participant_events)
      @client.post_sync_csv(table_id_or_name, sync_id, csv)
    end

    def serialize_all_to_csv(participant_events)
      CSV.generate do |csv|
        csv << SYNC_COLUMNS
        participant_events.each { |pe| csv << serialize_row(pe) }
      end
    end

    # --- Legacy per-record push (used by PushRecordJob / resync button) ---

    def push_participant_event(participant_event)
      fields = serialize_participant_event(participant_event)

      if participant_event.airtable_record_id.present?
        @client.update_record(PARTICIPANTS_TABLE, participant_event.airtable_record_id, fields)
      else
        result = @client.create_record(PARTICIPANTS_TABLE, fields)
        participant_event.update!(airtable_record_id: result["id"])
        result
      end
    end

    def pull_changes(table_name, since:)
      filter = "IS_AFTER(LAST_MODIFIED_TIME(), '#{since.iso8601}')"
      records = []
      offset = nil

      loop do
        options = { filter: filter, page_size: 100 }
        options[:offset] = offset if offset.present?

        result = @client.list_records(table_name, options)
        records.concat(result["records"])
        offset = result["offset"]

        break if offset.blank?
      end

      records
    end

    def sync_all(event = @event)
      event.participant_events
           .includes(*SYNC_INCLUDES)
           .find_each do |pe|
        push_participant_event(pe)
      rescue Airtable::Error => e
        Rails.logger.error("Failed to sync ParticipantEvent #{pe.id}: #{e.message}")
      end
    end

    private

    SYNC_INCLUDES = [
      :participant,
      { travel_inbound: :travel_legs, travel_outbound: :travel_legs },
      :accommodation, :dietary, :medical,
      :accessibility, :safeguarding_info,
      :room_assignment, :room,
      { guardian_participant_events: :guardian },
      :emergency_contacts, :consents, { scans: :scan_context }
    ].freeze

    def load_participant_events
      @event.participant_events
            .includes(*SYNC_INCLUDES)
            .to_a
    end

    def serialize_row(pe)
      participant = pe.participant
      travel_in = pe.travel_inbound
      travel_out = pe.travel_outbound
      accommodation = pe.accommodation
      dietary = pe.dietary
      medical = pe.medical
      accessibility = pe.accessibility
      safeguarding = pe.safeguarding_info
      primary_gpe = pe.guardian_participant_events.find { |gpe| gpe.is_primary_guardian }
      emergency_contact = pe.emergency_contacts.min_by { |ec| ec.priority || 999 }

      [
        pe.id,
        participant.email,
        participant.legal_first_name,
        participant.legal_last_name,
        participant.preferred_name,
        participant.pronouns,
        participant.date_of_birth&.iso8601,
        pe.age_on_event,
        pe.requires_guardian?,
        participant.phone,
        participant.tshirt_size,
        participant.country_of_residence,
        pe.status,
        # Both cells come from #check_in_time, so they cannot disagree.
        pe.check_in_time.present?,
        pe.check_in_time&.iso8601,
        pe.onboarding_complete?,
        pe.waiver_signed?,
        pe.slack_user_id,
        pe.nfc_badge_assigned?,
        travel_in&.mode,
        travel_in&.departure_city,
        travel_in&.last_arrival_time&.iso8601,
        flight_codes(travel_in),
        travel_in&.visa_required,
        travel_in&.visa_status,
        travel_out&.mode,
        travel_out&.departure_city,
        travel_out&.first_departure_time&.iso8601,
        flight_codes(travel_out),
        accommodation&.check_in_date&.iso8601,
        accommodation&.check_out_date&.iso8601,
        accommodation&.gender_identity,
        pe.room&.display_name,
        dietary&.diet_type,
        dietary&.cross_contamination_risk,
        dietary&.life_threatening_allergies,
        medical&.has_anaphylaxis_risk,
        medical&.has_allergies?,
        medical&.requires_refrigeration,
        accessibility&.uses_wheelchair,
        accessibility&.step_free_required,
        safeguarding&.high_support_flag,
        safeguarding&.freedom_waiver_granted,
        safeguarding&.can_leave_unaccompanied,
        primary_gpe&.guardian&.full_name,
        primary_gpe&.guardian&.email,
        primary_gpe&.guardian&.phone,
        primary_gpe&.status,
        emergency_contact&.name,
        emergency_contact&.phone
      ]
    end

    def flight_codes(travel)
      return nil unless travel&.plane? && travel.travel_legs.any?

      travel.travel_legs.filter_map(&:flight_code).join(", ").presence
    end

    def build_client
      Client.new(
        api_key: @event.config&.dig("airtable_api_key").presence || Rails.application.credentials.dig(:airtable, :api_key),
        base_id: @event.config&.dig("airtable_base_id").presence || Rails.application.credentials.dig(:airtable, :base_id)
      )
    end

    def serialize_participant_event(participant_event)
      participant = participant_event.participant

      {
        "Email" => participant.email,
        "First Name" => participant.legal_first_name,
        "Last Name" => participant.legal_last_name,
        "Preferred Name" => participant.preferred_name,
        "Status" => participant_event.status,
        "Event ID" => participant_event.event_id,
        "Participant Event ID" => participant_event.id
      }
    end
  end
end
