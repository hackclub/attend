module Exports
  Field = Struct.new(:key, :label, :category, :type, :includes, :extractor, :enum_values, keyword_init: true) do
    def leg_level?
      category == "flight_legs"
    end

    def filterable?
      !leg_level?
    end

    def operators
      Exports::Filter::OPERATORS_BY_TYPE.fetch(type, [])
    end
  end

  class FieldRegistry
    CATEGORIES = {
      "identity"           => { label: "Identity", tier: :identity, description: "Participant name and email" },
      "basic"              => { label: "Participant", tier: :general, description: "Contact details, address, and profile information" },
      "event_status"       => { label: "Event Status", tier: :general, description: "Registration status, check-in, and onboarding progress" },
      "travel"             => { label: "Travel", tier: :general, description: "Inbound and outbound travel details" },
      "flight_legs"        => { label: "Flight Legs", tier: :general, description: "Per-leg flight details (only in one-row-per-flight-leg mode)" },
      "groups"             => { label: "Groups", tier: :general, description: "Group memberships" },
      "accommodation"      => { label: "Accommodation", tier: :sensitive, description: "Check-in/out dates, rooming preferences, and room assignments" },
      "dietary"            => { label: "Dietary", tier: :sensitive, description: "Dietary requirements and food allergies" },
      "medical"            => { label: "Medical", tier: :sensitive, description: "Medical conditions, medications, and allergy flags" },
      "accessibility"      => { label: "Accessibility", tier: :sensitive, description: "Accessibility and support needs" },
      "safeguarding"       => { label: "Safeguarding", tier: :sensitive, description: "Safeguarding flags and pickup authorization" },
      "emergency_contacts" => { label: "Emergency Contacts", tier: :sensitive, description: "Emergency contact details" }
    }.freeze

    # Identity fields are available to every exporting role so sensitive
    # exports can always be paired with a name/email (matching the legacy
    # exports, which included name + email in medical/dietary/accommodation
    # CSVs for safeguarding leads).
    TIER_ROLES = {
      identity: %w[event_admin ops safeguarding_lead],
      general: %w[event_admin ops],
      sensitive: %w[event_admin safeguarding_lead]
    }.freeze

    ROW_MODES = %w[participant flight_leg].freeze

    fields = []

    # --- identity (participant name + email; available to all exporting roles) ---
    {
      "legal_first_name" => [ "Legal First Name", :string ],
      "legal_last_name" => [ "Legal Last Name", :string ],
      "preferred_name" => [ "Preferred Name", :string ],
      "email" => [ "Email", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "participant.#{attr}", label: label, category: "identity", type: type,
                          includes: :participant, extractor: ->(pe) { pe.participant.public_send(attr) })
    end
    fields << Field.new(key: "participant.full_legal_name", label: "Full Legal Name", category: "identity", type: :string,
                        includes: :participant, extractor: ->(pe) { pe.participant.full_name })
    fields << Field.new(key: "participant.id", label: "Participant ID", category: "identity", type: :string,
                        includes: nil, extractor: ->(pe) { pe.participant_id })

    # --- basic (participant) ---
    {
      "pronouns" => [ "Pronouns", :string ],
      "phone" => [ "Phone", :string ],
      "date_of_birth" => [ "Date of Birth", :date ],
      "tshirt_size" => [ "T-Shirt Size", :string ],
      "address_line_1" => [ "Address Line 1", :string ],
      "address_line_2" => [ "Address Line 2", :string ],
      "city" => [ "City", :string ],
      "state" => [ "State", :string ],
      "postal_code" => [ "Postal Code", :string ],
      "country_of_residence" => [ "Country of Residence", :string ],
      "slack_user_id" => [ "Slack ID", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "participant.#{attr}", label: label, category: "basic", type: type,
                          includes: :participant, extractor: ->(pe) { pe.participant.public_send(attr) })
    end
    fields << Field.new(key: "participant.age_at_event", label: "Age at Event Start", category: "basic", type: :string,
                        includes: :participant, extractor: ->(pe) { pe.participant.age_on(pe.event.starts_at&.to_date || Date.current) })
    fields << Field.new(key: "participant.engagement_preference", label: "Engagement Preference", category: "basic", type: :enum,
                        enum_values: Participant.engagement_preferences.keys, includes: :participant,
                        extractor: ->(pe) { pe.participant.engagement_preference })

    # --- event status ---
    fields << Field.new(key: "participant_event.status", label: "Status", category: "event_status", type: :enum,
                        enum_values: ParticipantEvent.statuses.keys, includes: nil, extractor: ->(pe) { pe.status })
    # Check-in is derived from scans (ParticipantEvent#check_in_time). The keys
    # stay as they are — saved ExportTemplates reference them.
    fields << Field.new(key: "participant_event.checked_in_at", label: "Checked In At", category: "event_status",
                        type: :datetime, includes: { scans: :scan_context },
                        extractor: ->(pe) { pe.check_in_time })
    fields << Field.new(key: "participant_event.checked_in", label: "Checked In", category: "event_status",
                        type: :boolean, includes: { scans: :scan_context },
                        extractor: ->(pe) { pe.check_in_time.present? })
    {
      "onboarding_completed_at" => "Onboarding Completed At",
      "code_of_conduct_accepted_at" => "Code of Conduct Accepted At",
      "nfc_badge_assigned_at" => "NFC Badge Assigned At"
    }.each do |attr, label|
      fields << Field.new(key: "participant_event.#{attr}", label: label, category: "event_status", type: :datetime,
                          includes: nil, extractor: ->(pe) { pe.public_send(attr) })
    end
    fields << Field.new(key: "participant_event.slack_user_id", label: "Event Slack ID", category: "event_status",
                        type: :string, includes: nil, extractor: ->(pe) { pe.slack_user_id })
    # Opt-in activity waivers. The registry is built once at boot and custom
    # documents are per-event rows, so these roll every optional document the
    # participant took up into one column rather than getting a column each —
    # enough to hand an activity provider their list.
    optional_consents = ->(pe) { pe.consents.select { |c| !c.withdrawn? && c.custom_document&.optional? } }
    fields << Field.new(key: "participant_event.optional_documents_added", label: "Optional Documents Added",
                        category: "event_status", type: :string, includes: { consents: :custom_document },
                        extractor: ->(pe) { optional_consents.call(pe).map { |c| c.custom_document.name }.sort.join(", ").presence })
    fields << Field.new(key: "participant_event.optional_documents_pending", label: "Optional Documents Awaiting Signature",
                        category: "event_status", type: :string, includes: { consents: :custom_document },
                        extractor: ->(pe) { optional_consents.call(pe).reject(&:signed?).map { |c| c.custom_document.name }.sort.join(", ").presence })

    # --- travel (inbound/outbound) ---
    %w[inbound outbound].each do |dir|
      travel = ->(pe) { pe.public_send("travel_#{dir}") }
      {
        "mode" => [ "Mode", :enum, Travel.modes.keys ],
        "carrier" => [ "Carrier", :string ],
        "flight_number" => [ "Flight Number", :string ],
        "departure_city" => [ "Departure City", :string ],
        "departure_time" => [ "Departure Time", :datetime ],
        "arrival_city" => [ "Arrival City", :string ],
        "arrival_time" => [ "Arrival Time", :datetime ],
        "bus_departure_location" => [ "Bus Departure Location", :string ],
        "bus_arrival_location" => [ "Bus Arrival Location", :string ],
        "train_departure_station" => [ "Train Departure Station", :string ],
        "train_arrival_station" => [ "Train Arrival Station", :string ],
        "is_unaccompanied_minor" => [ "Unaccompanied Minor", :boolean ],
        "passport_nationality" => [ "Passport Nationality", :string ],
        "visa_number" => [ "Visa Number", :string ],
        "origin_address" => [ "Origin Address", :string ],
        "notes" => [ "Notes", :string ]
      }.each do |attr, (label, type, enum_values)|
        fields << Field.new(key: "travel.#{dir}.#{attr}", label: "#{dir.capitalize} #{label}", category: "travel",
                            type: type, enum_values: enum_values, includes: { "travel_#{dir}": :travel_legs },
                            extractor: ->(pe) { travel.call(pe)&.public_send(attr) })
      end
      fields << Field.new(key: "travel.#{dir}.legs_summary", label: "#{dir.capitalize} Flight Legs", category: "travel",
                          type: :string, includes: { "travel_#{dir}": :travel_legs },
                          extractor: ->(pe) { Exports::LegSummary.call(travel.call(pe)) })
    end

    # --- flight legs (one-row-per-leg mode only) ---
    fields << Field.new(key: "leg.direction", label: "Direction", category: "flight_legs", type: :string,
                        includes: { travels: :travel_legs }, extractor: ->(pe, leg, travel) { travel&.direction })
    {
      "position" => [ "Leg", :string ],
      "flight_code" => [ "Flight Code", :string ],
      "confirmation_code" => [ "Confirmation Code", :string ],
      "departure_airport" => [ "Departure Airport", :string ],
      "arrival_airport" => [ "Arrival Airport", :string ],
      "departure_time" => [ "Scheduled Departure", :datetime ],
      "arrival_time" => [ "Scheduled Arrival", :datetime ],
      "live_status" => [ "Live Status", :string ],
      "live_departure_time" => [ "Live Departure", :datetime ],
      "live_arrival_time" => [ "Live Arrival", :datetime ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "leg.#{attr}", label: label, category: "flight_legs", type: type,
                          includes: { travels: :travel_legs }, extractor: ->(pe, leg, travel) { leg&.public_send(attr) })
    end

    # --- groups ---
    fields << Field.new(key: "groups.names", label: "Groups", category: "groups", type: :string,
                        includes: :groups, extractor: ->(pe) { pe.groups.map(&:name).sort.join(", ").presence })

    # --- accommodation ---
    {
      "check_in_date" => [ "Check In", :date ],
      "check_out_date" => [ "Check Out", :date ],
      "venue_name" => [ "Venue", :string ],
      "assigned_room" => [ "Assigned Room", :string ],
      "gender_identity" => [ "Gender Identity", :string ],
      "gender_identity_other" => [ "Gender Identity (Other)", :string ],
      "room_type_preference" => [ "Room Type Preference", :string ],
      "quiet_room_preference" => [ "Quiet Room Preference", :boolean ],
      "rooming_exempt" => [ "Rooming Exempt", :boolean ],
      "roommate_preferences" => [ "Roommate Preferences", :string ],
      "roommate_exclusions" => [ "Roommate Exclusions", :string ],
      "accessibility_needs" => [ "Accommodation Accessibility Needs", :string ],
      "notes" => [ "Accommodation Notes", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "accommodation.#{attr}", label: label, category: "accommodation", type: type,
                          includes: :accommodation, extractor: ->(pe) { pe.accommodation&.public_send(attr) })
    end
    fields << Field.new(key: "accommodation.preferred_roommate_genders", label: "Preferred Roommate Genders",
                        category: "accommodation", type: :string, includes: :accommodation,
                        extractor: ->(pe) { pe.accommodation&.preferred_roommate_genders&.join(", ").presence })
    fields << Field.new(key: "room.name", label: "Rooming Plan Room", category: "accommodation", type: :string,
                        includes: :room, extractor: ->(pe) { pe.room&.name })

    # --- dietary ---
    {
      "diet_type" => [ "Diet Type", :string ],
      "intolerances" => [ "Intolerances", :string ],
      "life_threatening_allergies" => [ "Life-Threatening Allergies", :string ],
      "cross_contamination_risk" => [ "Cross-Contamination Risk", :boolean ],
      "notes" => [ "Dietary Notes", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "dietary.#{attr}", label: label, category: "dietary", type: type,
                          includes: :dietary, extractor: ->(pe) { pe.dietary&.public_send(attr) })
    end

    # --- medical ---
    {
      "allergies" => [ "Allergies", :string ],
      "allergy_severity" => [ "Allergy Severity", :string ],
      "has_anaphylaxis_risk" => [ "Has Anaphylaxis Risk", :boolean ],
      "requires_refrigeration" => [ "Requires Refrigeration", :boolean ],
      "medical_conditions" => [ "Medical Conditions", :string ],
      "medications" => [ "Medications", :string ],
      "emergency_action_plan" => [ "Emergency Action Plan", :string ],
      "additional_notes" => [ "Medical Notes", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "medical.#{attr}", label: label, category: "medical", type: type,
                          includes: :medical, extractor: ->(pe) { pe.medical&.public_send(attr) })
    end
    fields << Field.new(key: "medical.has_medical_conditions", label: "Has Medical Conditions", category: "medical",
                        type: :boolean, includes: :medical,
                        extractor: ->(pe) { pe.medical&.medical_conditions.present? })

    # --- accessibility ---
    {
      "mobility_needs" => [ "Mobility Needs", :string ],
      "communication_needs" => [ "Communication Needs", :string ],
      "distance_limitations" => [ "Distance Limitations", :string ],
      "has_adhd" => [ "Has ADHD", :boolean ],
      "has_autism" => [ "Has Autism", :boolean ],
      "has_dyslexia" => [ "Has Dyslexia", :boolean ],
      "neurodivergent_notes" => [ "Neurodivergent Notes", :string ],
      "needs_captioning" => [ "Needs Captioning", :boolean ],
      "needs_large_print" => [ "Needs Large Print", :boolean ],
      "needs_sign_language" => [ "Needs Sign Language", :boolean ],
      "light_sensitivity" => [ "Light Sensitivity", :boolean ],
      "noise_sensitivity" => [ "Noise Sensitivity", :boolean ],
      "prayer_space_required" => [ "Prayer Space Required", :boolean ],
      "religious_practices" => [ "Religious Practices", :string ],
      "requires_private_space" => [ "Requires Private Space", :boolean ],
      "other_needs" => [ "Other Accessibility Needs", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "accessibility.#{attr}", label: label, category: "accessibility", type: type,
                          includes: :accessibility, extractor: ->(pe) { pe.accessibility&.public_send(attr) })
    end

    # --- safeguarding ---
    {
      "can_leave_unaccompanied" => [ "Can Leave Unaccompanied", :boolean ],
      "freedom_waiver_granted" => [ "Freedom Waiver Granted", :boolean ],
      "high_support_flag" => [ "High Support Flag", :boolean ],
      "high_support_notes" => [ "High Support Notes", :string ],
      "authorized_pickup_adults" => [ "Authorized Pickup Adults", :string ],
      "curfew_acknowledged" => [ "Curfew Acknowledged", :boolean ],
      "overnight_rules_acknowledged" => [ "Overnight Rules Acknowledged", :boolean ],
      "other_instructions" => [ "Other Safeguarding Instructions", :string ]
    }.each do |attr, (label, type)|
      fields << Field.new(key: "safeguarding.#{attr}", label: label, category: "safeguarding", type: type,
                          includes: :safeguarding_info, extractor: ->(pe) { pe.safeguarding_info&.public_send(attr) })
    end

    # --- emergency contacts (priority-ordered slots 1 and 2) ---
    [ 1, 2 ].each do |slot|
      contact = ->(pe) { pe.emergency_contacts.sort_by { |c| c.priority.to_i }[slot - 1] }
      %w[name phone email relationship].each do |attr|
        fields << Field.new(key: "emergency_contact.#{slot}.#{attr}", label: "Emergency Contact #{slot} #{attr.capitalize}",
                            category: "emergency_contacts", type: :string, includes: :emergency_contacts,
                            extractor: ->(pe) { contact.call(pe)&.public_send(attr) })
      end
    end

    FIELDS = fields.index_by(&:key).freeze

    PRESETS = {
      "participants" => {
        label: "Participants",
        description: "Basic participant information including name, email, phone, and status",
        row_mode: "participant",
        columns: %w[
          participant.legal_first_name participant.legal_last_name participant.preferred_name
          participant.email participant.phone participant.date_of_birth participant.slack_user_id
          participant_event.status
        ]
      },
      "travel" => {
        label: "Travel",
        description: "High-level travel summary for each participant",
        row_mode: "participant",
        columns: %w[
          participant.full_legal_name participant.email
          travel.inbound.mode travel.inbound.carrier travel.inbound.arrival_time
          travel.outbound.mode travel.outbound.carrier travel.outbound.departure_time
        ]
      },
      "flight_details" => {
        label: "Flight Details",
        description: "One row per flight leg with scheduled times and live status",
        row_mode: "flight_leg",
        columns: %w[
          participant.full_legal_name participant.email
          leg.direction leg.position leg.flight_code leg.departure_airport leg.arrival_airport
          leg.departure_time leg.arrival_time leg.live_status leg.live_departure_time leg.live_arrival_time
        ]
      },
      "accommodation" => {
        label: "Accommodation",
        description: "Accommodation details including check-in/out dates and room assignments",
        row_mode: "participant",
        columns: %w[
          participant.full_legal_name participant.email
          accommodation.check_in_date accommodation.check_out_date accommodation.gender_identity
          accommodation.preferred_roommate_genders accommodation.roommate_preferences accommodation.assigned_room
        ]
      },
      "dietary" => {
        label: "Dietary",
        description: "Dietary requirements and food allergies",
        row_mode: "participant",
        columns: %w[
          participant.full_legal_name participant.email
          dietary.diet_type dietary.intolerances dietary.life_threatening_allergies
          dietary.cross_contamination_risk dietary.notes
        ]
      },
      "medical_flags" => {
        label: "Medical Flags",
        description: "Medical flags for participants (anaphylaxis risk, refrigeration needs)",
        row_mode: "participant",
        columns: %w[
          participant.full_legal_name participant.email
          medical.has_anaphylaxis_risk medical.requires_refrigeration medical.has_medical_conditions
        ]
      }
    }.freeze

    class << self
      def fetch(key)
        FIELDS[key]
      end

      def all
        FIELDS.values
      end

      def categories_for(role:, global_admin: false)
        CATEGORIES.select { |_, config| global_admin || TIER_ROLES.fetch(config[:tier]).include?(role) }
      end

      def fields_for(role:, global_admin: false)
        permitted = categories_for(role: role, global_admin: global_admin).keys
        FIELDS.values.select { |f| permitted.include?(f.category) }
      end

      def permitted_keys(role:, global_admin: false)
        fields_for(role: role, global_admin: global_admin).map(&:key)
      end

      def includes_for(keys)
        keys.filter_map { |key| FIELDS[key]&.includes }.uniq
      end
    end
  end
end
