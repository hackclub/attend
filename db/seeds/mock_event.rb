puts "Creating mock event with participants..."

event = Event.find_or_create_by!(slug: "mock-summit-2025") do |e|
  e.name = "Mock Summit 2025"
  e.starts_at = 2.weeks.from_now
  e.ends_at = 2.weeks.from_now + 3.days
  e.location_city = "San Francisco"
  e.location_country = "United States"
  e.timezone = "America/Los_Angeles"
  e.registration_open_at = 1.month.ago
  e.registration_close_at = 1.week.from_now
  e.config = {
    "freedom_waivers_enabled" => true,
    "visa_options_enabled" => true,
    "accommodation_enabled" => true,
    "guardian_invites_locked" => false
  }
end
puts "Created event: #{event.name}"

def create_participant_with_data(event:, data:)
  participant = Participant.find_or_create_by!(email: data[:email]) do |p|
    p.legal_first_name = data[:first_name]
    p.legal_last_name = data[:last_name]
    p.preferred_name = data[:preferred_name]
    p.date_of_birth = data[:dob]
    p.phone = data[:phone]
    p.pronouns = data[:pronouns]
    p.country_of_residence = data[:country]
    p.city = data[:city]
    p.engagement_preference = data[:engagement] || "balanced"
  end

  pe = ParticipantEvent.find_or_create_by!(participant: participant, event: event) do |pe_record|
    pe_record.status = data[:status]
    pe_record.onboarding_step = data[:onboarding_step] || 1
  end
  pe.update!(status: data[:status])

  if data[:travel_inbound]
    Travel.find_or_create_by!(participant_event: pe, direction: :inbound) do |t|
      t.mode = data[:travel_inbound][:mode]
      t.arrival_time = data[:travel_inbound][:arrival_time]
      t.arrival_city = data[:travel_inbound][:arrival_city]
      t.visa_status = data[:travel_inbound][:visa_status] || "not_required"
    end
  end

  if data[:travel_outbound]
    Travel.find_or_create_by!(participant_event: pe, direction: :outbound) do |t|
      t.mode = data[:travel_outbound][:mode]
      t.departure_time = data[:travel_outbound][:departure_time]
      t.departure_city = data[:travel_outbound][:departure_city]
    end
  end

  if data[:accommodation]
    Accommodation.find_or_create_by!(participant_event: pe) do |a|
      a.gender_identity = data[:accommodation][:gender_identity]
      a.preferred_roommate_genders = data[:accommodation][:preferred_roommate_genders]
      a.roommate_preferences = data[:accommodation][:roommate_preferences]
      a.check_in_date = event.starts_at.to_date
      a.check_out_date = event.ends_at.to_date
    end
  end

  if data[:medical]
    Medical.find_or_create_by!(participant_event: pe) do |m|
      m.allergies = data[:medical][:allergies]
      m.has_anaphylaxis_risk = data[:medical][:anaphylaxis] || false
      m.medical_conditions = data[:medical][:conditions]
      m.medications = data[:medical][:medications]
      m.requires_refrigeration = data[:medical][:refrigeration] || false
    end
  end

  if data[:dietary]
    Dietary.find_or_create_by!(participant_event: pe) do |d|
      d.diet_type = data[:dietary][:type]
      d.intolerances = data[:dietary][:intolerances]
      d.life_threatening_allergies = data[:dietary][:life_threatening]
      d.cross_contamination_risk = data[:dietary][:cross_contamination] || false
    end
  end

  if data[:accessibility]
    Accessibility.find_or_create_by!(participant_event: pe) do |a|
      a.noise_sensitivity = data[:accessibility][:noise_sensitivity] || false
      a.uses_wheelchair = data[:accessibility][:wheelchair] || false
      a.step_free_required = data[:accessibility][:step_free] || false
      a.needs_sign_language = data[:accessibility][:sign_language] || false
      a.needs_captioning = data[:accessibility][:captioning] || false
      a.needs_large_print = data[:accessibility][:large_print] || false
      a.sensory_needs = data[:accessibility][:sensory_needs]
      a.mobility_needs = data[:accessibility][:mobility_needs]
      a.communication_needs = data[:accessibility][:communication_needs]
    end
  end

  if data[:safeguarding]
    SafeguardingInfo.find_or_create_by!(participant_event: pe) do |s|
      s.can_leave_unaccompanied = data[:safeguarding][:can_leave] || false
      s.freedom_waiver_granted = data[:safeguarding][:freedom_waiver] || false
      s.high_support_flag = data[:safeguarding][:high_support] || false
      s.high_support_notes = data[:safeguarding][:high_support_notes]
      s.authorized_pickup_adults = data[:safeguarding][:authorized_pickup]
    end
  end

  if data[:emergency_contacts]
    data[:emergency_contacts].each_with_index do |ec_data, index|
      EmergencyContact.find_or_create_by!(participant_event: pe, phone: ec_data[:phone]) do |ec|
        ec.name = ec_data[:name]
        ec.relationship = ec_data[:relationship]
        ec.priority = index + 1
      end
    end
  end

  if data[:consents]
    data[:consents].each do |consent_data|
      Consent.find_or_create_by!(participant_event: pe, consent_type: consent_data[:type]) do |c|
        c.status = consent_data[:status]
        c.signed_at = consent_data[:status] == "signed" ? 1.day.ago : nil
        c.participant_signed_at = consent_data[:status] == "signed" ? 1.day.ago : nil
      end
    end
  end

  if data[:guardian]
    guardian = Guardian.find_or_create_by!(email: data[:guardian][:email]) do |g|
      g.legal_first_name = data[:guardian][:first_name]
      g.legal_last_name = data[:guardian][:last_name]
      g.phone = data[:guardian][:phone]
      g.relationship_default = data[:guardian][:relationship]
      g.country = data[:guardian][:country]
      g.time_zone = data[:guardian][:timezone]
    end

    gpe = GuardianParticipantEvent.find_or_create_by!(guardian: guardian, participant_event: pe) do |gpe_record|
      gpe_record.relationship = data[:guardian][:relationship]
      gpe_record.is_primary_guardian = true
      gpe_record.status = data[:guardian][:status]
      gpe_record.accepted_at = data[:guardian][:status] != "pending" ? 2.days.ago : nil
    end
    gpe.update!(status: data[:guardian][:status])

    if data[:guardian][:emergency_contacts]
      data[:guardian][:emergency_contacts].each_with_index do |ec_data, index|
        EmergencyContact.find_or_create_by!(guardian_participant_event: gpe, phone: ec_data[:phone]) do |ec|
          ec.name = ec_data[:name]
          ec.relationship = ec_data[:relationship]
          ec.priority = index + 1
        end
      end
    end
  end

  puts "  Created: #{participant.full_name} (#{data[:status]})"
  { participant: participant, participant_event: pe }
end

PARTICIPANTS = [
  # === SIBLING PAIR 1: The Chen siblings (Marcus 17M and Emily 15F) ===
  {
    email: "marcus.chen@example.com",
    first_name: "Marcus",
    last_name: "Chen",
    preferred_name: nil,
    dob: Date.new(2008, 4, 12),
    phone: "+14155550101",
    pronouns: "he/him",
    country: "United States",
    city: "San Jose",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    sibling_group: "chen_siblings",
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "David Chen", phone: "+14155550102", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "david.chen@example.com",
      first_name: "David",
      last_name: "Chen",
      phone: "+14155550102",
      relationship: "Father",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: [ { name: "Linda Chen", phone: "+14155550103", relationship: "Mother" } ]
    }
  },
  {
    email: "emily.chen@example.com",
    first_name: "Emily",
    last_name: "Chen",
    preferred_name: "Em",
    dob: Date.new(2010, 9, 3),
    phone: "+14155550104",
    pronouns: "she/her",
    country: "United States",
    city: "San Jose",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    sibling_group: "chen_siblings",
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "vegetarian", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "David Chen", phone: "+14155550102", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "david.chen@example.com",
      first_name: "David",
      last_name: "Chen",
      phone: "+14155550102",
      relationship: "Father",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },

  # === SIBLING PAIR 2: The Okonkwo siblings (Daniel 16M and Chioma 14F) ===
  {
    email: "daniel.okonkwo@example.com",
    first_name: "Daniel",
    last_name: "Okonkwo",
    preferred_name: "Danny",
    dob: Date.new(2009, 2, 14),
    phone: "+14155550105",
    pronouns: "he/him",
    country: "United States",
    city: "Atlanta",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    sibling_group: "okonkwo_siblings",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Chukwu Okonkwo", phone: "+14155550106", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "chukwu.okonkwo@example.com",
      first_name: "Chukwu",
      last_name: "Okonkwo",
      phone: "+14155550106",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: [ { name: "Adaeze Okonkwo", phone: "+14155550107", relationship: "Mother" } ]
    }
  },
  {
    email: "chioma.okonkwo@example.com",
    first_name: "Chioma",
    last_name: "Okonkwo",
    preferred_name: nil,
    dob: Date.new(2011, 6, 22),
    phone: "+14155550108",
    pronouns: "she/her",
    country: "United States",
    city: "Atlanta",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    sibling_group: "okonkwo_siblings",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "Peanuts", anaphylaxis: true, conditions: nil, medications: "EpiPen" },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: "Peanuts", cross_contamination: true },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Chukwu Okonkwo", phone: "+14155550106", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "chukwu.okonkwo@example.com",
      first_name: "Chukwu",
      last_name: "Okonkwo",
      phone: "+14155550106",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },

  # === CONFIRMED MALE PARTICIPANTS ===
  {
    email: "jake.martinez@example.com",
    first_name: "Jake",
    last_name: "Martinez",
    preferred_name: nil,
    dob: Date.new(2007, 8, 5),
    phone: "+14155550110",
    pronouns: "he/him",
    country: "United States",
    city: "Los Angeles",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "ryan.kim@example.com",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: "Want to room with Ryan Kim" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Maria Martinez", phone: "+14155550111", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "maria.martinez@example.com",
      first_name: "Maria",
      last_name: "Martinez",
      phone: "+14155550111",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "ryan.kim@example.com",
    first_name: "Ryan",
    last_name: "Kim",
    preferred_name: nil,
    dob: Date.new(2007, 11, 18),
    phone: "+14155550112",
    pronouns: "he/him",
    country: "United States",
    city: "Seattle",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "jake.martinez@example.com",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: "Want to room with Jake Martinez" },
    medical: { allergies: "None", anaphylaxis: false, conditions: "ADHD", medications: "Adderall" },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "James Kim", phone: "+14155550113", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "james.kim@example.com",
      first_name: "James",
      last_name: "Kim",
      phone: "+14155550113",
      relationship: "Father",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "tyler.johnson@example.com",
    first_name: "Tyler",
    last_name: "Johnson",
    preferred_name: "Ty",
    dob: Date.new(2008, 3, 29),
    phone: "+14155550114",
    pronouns: "he/him",
    country: "United States",
    city: "Denver",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Steve Johnson", phone: "+14155550115", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "steve.johnson@example.com",
      first_name: "Steve",
      last_name: "Johnson",
      phone: "+14155550115",
      relationship: "Father",
      country: "United States",
      timezone: "America/Denver",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "kevin.nguyen@example.com",
    first_name: "Kevin",
    last_name: "Nguyen",
    preferred_name: nil,
    dob: Date.new(2009, 7, 7),
    phone: "+14155550116",
    pronouns: "he/him",
    country: "United States",
    city: "Houston",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Linh Nguyen", phone: "+14155550117", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "linh.nguyen@example.com",
      first_name: "Linh",
      last_name: "Nguyen",
      phone: "+14155550117",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "ethan.williams@example.com",
    first_name: "Ethan",
    last_name: "Williams",
    preferred_name: nil,
    dob: Date.new(2010, 1, 15),
    phone: "+14155550118",
    pronouns: "he/him",
    country: "United States",
    city: "Phoenix",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Robert Williams", phone: "+14155550119", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "robert.williams@example.com",
      first_name: "Robert",
      last_name: "Williams",
      phone: "+14155550119",
      relationship: "Father",
      country: "United States",
      timezone: "America/Phoenix",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "alex.brown@example.com",
    first_name: "Alex",
    last_name: "Brown",
    preferred_name: nil,
    dob: Date.new(2008, 5, 21),
    phone: "+14155550120",
    pronouns: "he/him",
    country: "United States",
    city: "Portland",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "train", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "train", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "Shellfish", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: "Shellfish", life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Michael Brown", phone: "+14155550121", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "michael.brown@example.com",
      first_name: "Michael",
      last_name: "Brown",
      phone: "+14155550121",
      relationship: "Father",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "noah.davis@example.com",
    first_name: "Noah",
    last_name: "Davis",
    preferred_name: nil,
    dob: Date.new(2007, 12, 3),
    phone: "+14155550122",
    pronouns: "he/him",
    country: "United States",
    city: "Austin",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "liam.garcia@example.com",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: "Would like to room with Liam Garcia" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Jennifer Davis", phone: "+14155550123", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "jennifer.davis@example.com",
      first_name: "Jennifer",
      last_name: "Davis",
      phone: "+14155550123",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "liam.garcia@example.com",
    first_name: "Liam",
    last_name: "Garcia",
    preferred_name: nil,
    dob: Date.new(2008, 6, 19),
    phone: "+14155550124",
    pronouns: "he/him",
    country: "United States",
    city: "Miami",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "noah.davis@example.com",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: "Would like to room with Noah Davis" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Carlos Garcia", phone: "+14155550125", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "carlos.garcia@example.com",
      first_name: "Carlos",
      last_name: "Garcia",
      phone: "+14155550125",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "mason.lee@example.com",
    first_name: "Mason",
    last_name: "Lee",
    preferred_name: nil,
    dob: Date.new(2009, 9, 8),
    phone: "+14155550126",
    pronouns: "he/him",
    country: "United States",
    city: "San Diego",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Andrew Lee", phone: "+14155550127", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "andrew.lee@example.com",
      first_name: "Andrew",
      last_name: "Lee",
      phone: "+14155550127",
      relationship: "Father",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "jackson.thompson@example.com",
    first_name: "Jackson",
    last_name: "Thompson",
    preferred_name: "Jack",
    dob: Date.new(2010, 4, 25),
    phone: "+14155550128",
    pronouns: "he/him",
    country: "United States",
    city: "Chicago",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "vegetarian", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Sarah Thompson", phone: "+14155550129", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "sarah.thompson@example.com",
      first_name: "Sarah",
      last_name: "Thompson",
      phone: "+14155550129",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "aiden.white@example.com",
    first_name: "Aiden",
    last_name: "White",
    preferred_name: nil,
    dob: Date.new(2008, 10, 12),
    phone: "+14155550130",
    pronouns: "he/him",
    country: "United States",
    city: "Boston",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Thomas White", phone: "+14155550131", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "thomas.white@example.com",
      first_name: "Thomas",
      last_name: "White",
      phone: "+14155550131",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "lucas.harris@example.com",
    first_name: "Lucas",
    last_name: "Harris",
    preferred_name: nil,
    dob: Date.new(2009, 2, 28),
    phone: "+14155550132",
    pronouns: "he/him",
    country: "United States",
    city: "Nashville",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "William Harris", phone: "+14155550133", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "william.harris@example.com",
      first_name: "William",
      last_name: "Harris",
      phone: "+14155550133",
      relationship: "Father",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "benjamin.clark@example.com",
    first_name: "Benjamin",
    last_name: "Clark",
    preferred_name: "Ben",
    dob: Date.new(2007, 7, 14),
    phone: "+14155550134",
    pronouns: "he/him",
    country: "United States",
    city: "Minneapolis",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "Bee stings", anaphylaxis: true, conditions: nil, medications: "EpiPen" },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Richard Clark", phone: "+14155550135", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "richard.clark@example.com",
      first_name: "Richard",
      last_name: "Clark",
      phone: "+14155550135",
      relationship: "Father",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "henry.robinson@example.com",
    first_name: "Henry",
    last_name: "Robinson",
    preferred_name: nil,
    dob: Date.new(2010, 11, 9),
    phone: "+14155550136",
    pronouns: "he/him",
    country: "United States",
    city: "Detroit",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "David Robinson", phone: "+14155550137", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "david.robinson@example.com",
      first_name: "David",
      last_name: "Robinson",
      phone: "+14155550137",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "sebastian.lewis@example.com",
    first_name: "Sebastian",
    last_name: "Lewis",
    preferred_name: "Seb",
    dob: Date.new(2008, 8, 22),
    phone: "+14155550138",
    pronouns: "he/him",
    country: "United States",
    city: "Philadelphia",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: "Asthma", medications: "Inhaler" },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Patricia Lewis", phone: "+14155550139", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "patricia.lewis@example.com",
      first_name: "Patricia",
      last_name: "Lewis",
      phone: "+14155550139",
      relationship: "Mother",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "caleb.walker@example.com",
    first_name: "Caleb",
    last_name: "Walker",
    preferred_name: nil,
    dob: Date.new(2009, 5, 17),
    phone: "+14155550140",
    pronouns: "he/him",
    country: "United States",
    city: "Salt Lake City",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Mark Walker", phone: "+14155550141", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "mark.walker@example.com",
      first_name: "Mark",
      last_name: "Walker",
      phone: "+14155550141",
      relationship: "Father",
      country: "United States",
      timezone: "America/Denver",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "owen.hall@example.com",
    first_name: "Owen",
    last_name: "Hall",
    preferred_name: nil,
    dob: Date.new(2007, 3, 6),
    phone: "+14155550142",
    pronouns: "he/him",
    country: "United States",
    city: "Charlotte",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Kevin Hall", phone: "+14155550143", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "kevin.hall@example.com",
      first_name: "Kevin",
      last_name: "Hall",
      phone: "+14155550143",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "dylan.young@example.com",
    first_name: "Dylan",
    last_name: "Young",
    preferred_name: nil,
    dob: Date.new(2011, 1, 30),
    phone: "+14155550144",
    pronouns: "he/him",
    country: "United States",
    city: "Columbus",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Brian Young", phone: "+14155550145", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "brian.young@example.com",
      first_name: "Brian",
      last_name: "Young",
      phone: "+14155550145",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "nathan.king@example.com",
    first_name: "Nathan",
    last_name: "King",
    preferred_name: "Nate",
    dob: Date.new(2008, 12, 11),
    phone: "+14155550146",
    pronouns: "he/him",
    country: "United States",
    city: "Indianapolis",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Gary King", phone: "+14155550147", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "gary.king@example.com",
      first_name: "Gary",
      last_name: "King",
      phone: "+14155550147",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "isaiah.wright@example.com",
    first_name: "Isaiah",
    last_name: "Wright",
    preferred_name: nil,
    dob: Date.new(2009, 6, 4),
    phone: "+14155550148",
    pronouns: "he/him",
    country: "United States",
    city: "San Antonio",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "halal", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Omar Wright", phone: "+14155550149", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "omar.wright@example.com",
      first_name: "Omar",
      last_name: "Wright",
      phone: "+14155550149",
      relationship: "Father",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "joshua.lopez@example.com",
    first_name: "Joshua",
    last_name: "Lopez",
    preferred_name: "Josh",
    dob: Date.new(2010, 3, 18),
    phone: "+14155550150",
    pronouns: "he/him",
    country: "United States",
    city: "Dallas",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Roberto Lopez", phone: "+14155550151", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "roberto.lopez@example.com",
      first_name: "Roberto",
      last_name: "Lopez",
      phone: "+14155550151",
      relationship: "Father",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "andrew.hill@example.com",
    first_name: "Andrew",
    last_name: "Hill",
    preferred_name: "Andy",
    dob: Date.new(2007, 9, 27),
    phone: "+14155550152",
    pronouns: "he/him",
    country: "United States",
    city: "Raleigh",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "male", preferred_roommate_genders: [ "male" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Scott Hill", phone: "+14155550153", relationship: "Father" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "scott.hill@example.com",
      first_name: "Scott",
      last_name: "Hill",
      phone: "+14155550153",
      relationship: "Father",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },

  # === CONFIRMED FEMALE PARTICIPANTS ===
  {
    email: "sophia.anderson@example.com",
    first_name: "Sophia",
    last_name: "Anderson",
    preferred_name: nil,
    dob: Date.new(2008, 4, 2),
    phone: "+14155550160",
    pronouns: "she/her",
    country: "United States",
    city: "Seattle",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "olivia.moore@example.com",
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: "Would like to room with Olivia Moore" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Lisa Anderson", phone: "+14155550161", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "lisa.anderson@example.com",
      first_name: "Lisa",
      last_name: "Anderson",
      phone: "+14155550161",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "olivia.moore@example.com",
    first_name: "Olivia",
    last_name: "Moore",
    preferred_name: "Liv",
    dob: Date.new(2008, 7, 16),
    phone: "+14155550162",
    pronouns: "she/her",
    country: "United States",
    city: "Portland",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "sophia.anderson@example.com",
    travel_inbound: { mode: "train", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "train", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: "Would like to room with Sophia Anderson" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "vegan", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Karen Moore", phone: "+14155550163", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "karen.moore@example.com",
      first_name: "Karen",
      last_name: "Moore",
      phone: "+14155550163",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "isabella.taylor@example.com",
    first_name: "Isabella",
    last_name: "Taylor",
    preferred_name: "Izzy",
    dob: Date.new(2009, 11, 5),
    phone: "+14155550164",
    pronouns: "she/her",
    country: "United States",
    city: "Denver",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: "Lactose", life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Amy Taylor", phone: "+14155550165", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "amy.taylor@example.com",
      first_name: "Amy",
      last_name: "Taylor",
      phone: "+14155550165",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Denver",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "mia.jackson@example.com",
    first_name: "Mia",
    last_name: "Jackson",
    preferred_name: nil,
    dob: Date.new(2010, 2, 20),
    phone: "+14155550166",
    pronouns: "she/her",
    country: "United States",
    city: "Austin",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: { noise_sensitivity: true, sensory_needs: "Prefers quiet environments" },
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Rebecca Jackson", phone: "+14155550167", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "rebecca.jackson@example.com",
      first_name: "Rebecca",
      last_name: "Jackson",
      phone: "+14155550167",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "ava.martin@example.com",
    first_name: "Ava",
    last_name: "Martin",
    preferred_name: nil,
    dob: Date.new(2007, 8, 9),
    phone: "+14155550168",
    pronouns: "she/her",
    country: "United States",
    city: "New York",
    engagement: "very_social",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "vegetarian", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Christine Martin", phone: "+14155550169", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "christine.martin@example.com",
      first_name: "Christine",
      last_name: "Martin",
      phone: "+14155550169",
      relationship: "Mother",
      country: "United States",
      timezone: "America/New_York",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "harper.lee.attendee@example.com",
    first_name: "Harper",
    last_name: "Lee",
    preferred_name: nil,
    dob: Date.new(2009, 10, 14),
    phone: "+14155550170",
    pronouns: "she/her",
    country: "United States",
    city: "San Francisco",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Michelle Lee", phone: "+14155550171", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "michelle.lee@example.com",
      first_name: "Michelle",
      last_name: "Lee",
      phone: "+14155550171",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "ella.harris@example.com",
    first_name: "Ella",
    last_name: "Harris",
    preferred_name: nil,
    dob: Date.new(2011, 5, 28),
    phone: "+14155550172",
    pronouns: "she/her",
    country: "United States",
    city: "Chicago",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "female", preferred_roommate_genders: [ "female" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Nancy Harris", phone: "+14155550173", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "nancy.harris@example.com",
      first_name: "Nancy",
      last_name: "Harris",
      phone: "+14155550173",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Chicago",
      status: "completed",
      emergency_contacts: []
    }
  },

  # === TRANS/NON-BINARY PARTICIPANTS ===
  {
    email: "kai.rivera@example.com",
    first_name: "Kyle",
    last_name: "Rivera",
    preferred_name: "Kai",
    dob: Date.new(2008, 1, 12),
    phone: "+14155550180",
    pronouns: "they/them",
    country: "United States",
    city: "Los Angeles",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "plane", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "plane", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "non_binary", preferred_roommate_genders: [ "non_binary", "female" ], roommate_preferences: "Gender-affirming environment preferred" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Elena Rivera", phone: "+14155550181", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "elena.rivera@example.com",
      first_name: "Elena",
      last_name: "Rivera",
      phone: "+14155550181",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "alex.torres@example.com",
    first_name: "Alexandra",
    last_name: "Torres",
    preferred_name: "Alex",
    dob: Date.new(2009, 6, 23),
    phone: "+14155550182",
    pronouns: "he/him",
    country: "United States",
    city: "San Diego",
    engagement: "social_with_downtime",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "sam.patel@example.com",
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "trans_male", preferred_roommate_genders: [ "male", "trans_male" ], roommate_preferences: "Would like to room with Sam Patel" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: "Testosterone" },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Maria Torres", phone: "+14155550183", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "maria.torres@example.com",
      first_name: "Maria",
      last_name: "Torres",
      phone: "+14155550183",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "sam.patel@example.com",
    first_name: "Samuel",
    last_name: "Patel",
    preferred_name: "Sam",
    dob: Date.new(2009, 9, 8),
    phone: "+14155550184",
    pronouns: "they/he",
    country: "United States",
    city: "San Jose",
    engagement: "balanced",
    status: "complete",
    onboarding_step: 5,
    roommate_request: "alex.torres@example.com",
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "non_binary", preferred_roommate_genders: [ "male", "non_binary" ], roommate_preferences: "Would like to room with Alex Torres" },
    medical: { allergies: "None", anaphylaxis: false, conditions: nil, medications: nil },
    dietary: { type: "vegetarian", intolerances: nil, life_threatening: nil },
    accessibility: {},
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Priya Patel", phone: "+14155550185", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "priya.patel@example.com",
      first_name: "Priya",
      last_name: "Patel",
      phone: "+14155550185",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },
  {
    email: "jordan.scott@example.com",
    first_name: "Jessica",
    last_name: "Scott",
    preferred_name: "Jordan",
    dob: Date.new(2010, 4, 17),
    phone: "+14155550186",
    pronouns: "she/they",
    country: "United States",
    city: "Oakland",
    engagement: "mostly_focused",
    status: "complete",
    onboarding_step: 5,
    travel_inbound: { mode: "car", arrival_time: 2.weeks.from_now, arrival_city: "San Francisco" },
    travel_outbound: { mode: "car", departure_time: 2.weeks.from_now + 3.days, departure_city: "San Francisco" },
    accommodation: { gender_identity: "non_binary", preferred_roommate_genders: [ "female", "non_binary" ], roommate_preferences: nil },
    medical: { allergies: "None", anaphylaxis: false, conditions: "Anxiety", medications: nil },
    dietary: { type: "omnivore", intolerances: nil, life_threatening: nil },
    accessibility: { noise_sensitivity: true },
    safeguarding: { can_leave: false, freedom_waiver: false },
    emergency_contacts: [ { name: "Diana Scott", phone: "+14155550187", relationship: "Mother" } ],
    consents: [ { type: "code_of_conduct", status: "signed" }, { type: "waiver", status: "signed" }, { type: "media", status: "signed" } ],
    guardian: {
      email: "diana.scott@example.com",
      first_name: "Diana",
      last_name: "Scott",
      phone: "+14155550187",
      relationship: "Mother",
      country: "United States",
      timezone: "America/Los_Angeles",
      status: "completed",
      emergency_contacts: []
    }
  },

  # === A FEW NON-CONFIRMED PARTICIPANTS FOR VARIETY ===
  {
    email: "pending.pete@example.com",
    first_name: "Pete",
    last_name: "Pending",
    preferred_name: nil,
    dob: Date.new(2009, 3, 10),
    phone: "+14155550190",
    pronouns: "he/him",
    country: "United States",
    city: "Sacramento",
    engagement: "balanced",
    status: "in_progress",
    onboarding_step: 2,
    travel_inbound: nil,
    travel_outbound: nil,
    accommodation: nil,
    medical: nil,
    dietary: nil,
    accessibility: nil,
    safeguarding: nil,
    emergency_contacts: [],
    consents: []
  },
  {
    email: "waitlist.wendy@example.com",
    first_name: "Wendy",
    last_name: "Waitlist",
    preferred_name: nil,
    dob: Date.new(2008, 12, 5),
    phone: "+14155550191",
    pronouns: "she/her",
    country: "United States",
    city: "Fresno",
    engagement: "very_social",
    status: "invited",
    onboarding_step: 1,
    travel_inbound: nil,
    travel_outbound: nil,
    accommodation: nil,
    medical: nil,
    dietary: nil,
    accessibility: nil,
    safeguarding: nil,
    emergency_contacts: [],
    consents: []
  }
]

puts "\nCreating #{PARTICIPANTS.count} participants with varying edge cases..."
participant_events = {}
PARTICIPANTS.each do |data|
  result = create_participant_with_data(event: event, data: data)
  participant_events[data[:email]] = result[:participant_event]
end

puts "\nCreating sibling groups..."
sibling_groups = PARTICIPANTS.group_by { |p| p[:sibling_group] }.compact.reject { |k, _| k.nil? }
sibling_groups.each do |group_name, members|
  sibling_group = SiblingGroup.find_or_create_by!(id: SiblingGroup.find_by("id IS NOT NULL")&.id || SecureRandom.uuid) do |sg|
  end
  sibling_group = SiblingGroup.create!

  members.each do |member_data|
    participant = Participant.find_by(email: member_data[:email])
    SiblingMembership.find_or_create_by!(sibling_group: sibling_group, participant: participant)
  end
  puts "  Created sibling group: #{members.map { |m| m[:first_name] }.join(' & ')}"
end

puts "\nCreating roommate preferences..."
PARTICIPANTS.select { |p| p[:roommate_request] }.each do |requester_data|
  requester_pe = participant_events[requester_data[:email]]
  preferred_pe = participant_events[requester_data[:roommate_request]]

  next unless requester_pe && preferred_pe

  RoommatePreference.find_or_create_by!(
    participant_event: requester_pe,
    preferred_participant_event: preferred_pe
  ) do |rp|
    rp.rank = 1
  end
  puts "  #{requester_data[:first_name]} wants to room with #{PARTICIPANTS.find { |p| p[:email] == requester_data[:roommate_request] }&.dig(:first_name)}"
end

puts "\nMock event seeding complete!"
puts "Event: #{event.name} (#{event.slug})"
puts "Total participants: #{event.participants.count}"
puts "Status breakdown:"
ParticipantEvent.statuses.keys.each do |status|
  count = event.participant_events.where(status: status).count
  puts "  #{status}: #{count}" if count > 0
end
