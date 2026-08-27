puts "Seeding database..."

event = Event.find_or_create_by!(slug: "midnight-vienna-2026") do |e|
  e.name = "Midnight, Vienna 2026"
  e.starts_at = DateTime.new(2026, 6, 15, 18, 0, 0)
  e.ends_at = DateTime.new(2026, 6, 18, 12, 0, 0)
  e.location_city = "Vienna"
  e.location_country = "Austria"
  e.timezone = "America/Los_Angeles"
  e.registration_open_at = DateTime.new(2025, 12, 1, 0, 0, 0)
  e.registration_close_at = DateTime.new(2026, 5, 15, 23, 59, 59)
  e.config = {
    "contact_email" => "midnight@hackclub.com",
    "required_onboarding_steps" => %w[profile travel accommodation health guardian],
    "required_guardian_steps" => %w[details emergency permissions consents],
    "required_consent_types" => %w[event_consent medical_release code_of_conduct media waiver]
  }
end
puts "Created event: #{event.name}"

if Rails.env.development?
  admin = User.find_or_create_by!(email: "admin@hackclub.com") do |u|
    u.name = "Admin User"
    u.password = "password123"
    u.global_role = "global_admin"
  end
  puts "Created admin user: #{admin.email}"

  event_admin = User.find_or_create_by!(email: "eventadmin@hackclub.com") do |u|
    u.name = "Event Admin"
    u.password = "password123"
    u.global_role = "no_role"
  end
  EventRoleAssignment.find_or_create_by!(user: event_admin, event: event, role: "event_admin")
  puts "Created event admin: #{event_admin.email}"

  ops_staff = User.find_or_create_by!(email: "ops@hackclub.com") do |u|
    u.name = "Ops Staff"
    u.password = "password123"
    u.global_role = "no_role"
  end
  EventRoleAssignment.find_or_create_by!(user: ops_staff, event: event, role: "ops")
  puts "Created ops staff: #{ops_staff.email}"

  limited_staff = User.find_or_create_by!(email: "limited@hackclub.com") do |u|
    u.name = "Limited Staff"
    u.password = "password123"
    u.global_role = "no_role"
  end
  EventRoleAssignment.find_or_create_by!(user: limited_staff, event: event, role: "limited")
  puts "Created limited staff: #{limited_staff.email}"

  safeguarding = User.find_or_create_by!(email: "safeguarding@hackclub.com") do |u|
    u.name = "Safeguarding Lead"
    u.password = "password123"
    u.global_role = "no_role"
  end
  EventRoleAssignment.find_or_create_by!(user: safeguarding, event: event, role: "safeguarding_lead")
  puts "Created safeguarding lead: #{safeguarding.email}"

  participant_user = User.find_or_create_by!(email: "participant@example.com") do |u|
    u.name = "Test Participant"
    u.password = "password123"
    u.global_role = "no_role"
  end

  participant = Participant.find_or_create_by!(email: "participant@example.com") do |p|
    p.user = participant_user
    p.legal_first_name = "Test"
    p.legal_last_name = "Participant"
    p.preferred_name = "Testy"
    p.date_of_birth = Date.new(2008, 5, 15)
    p.phone = "+12025551234"
    p.pronouns = "they/them"
    p.country_of_residence = "United States"
    p.city = "San Francisco"
  end
  puts "Created participant: #{participant.full_name}"

  pe = ParticipantEvent.find_or_create_by!(participant: participant, event: event) do |pe|
    pe.status = "in_progress"
    pe.onboarding_step = 1
  end
  puts "Created participant event registration"

  guardian = Guardian.find_or_create_by!(email: "guardian@example.com") do |g|
    g.legal_first_name = "Parent"
    g.legal_last_name = "Guardian"
    g.phone = "+12025559876"
    g.relationship_default = "Parent"
    g.country = "United States"
    g.time_zone = "America/Los_Angeles"
  end
  puts "Created guardian: #{guardian.full_name}"

  gpe = GuardianParticipantEvent.find_or_create_by!(
    guardian: guardian,
    participant_event: pe
  ) do |gpe|
    gpe.relationship = "Parent"
    gpe.is_primary_guardian = true
    gpe.status = "pending"
  end
  puts "Created guardian-participant link"

  Medical.find_or_create_by!(participant_event: pe) do |m|
    m.allergies = "Peanuts"
    m.has_anaphylaxis_risk = true
    m.medical_conditions = "Mild asthma"
  end

  Dietary.find_or_create_by!(participant_event: pe) do |d|
    d.diet_type = "vegetarian"
    d.cross_contamination_risk = true
    d.life_threatening_allergies = "Peanuts - severe allergy"
  end

  Accessibility.find_or_create_by!(participant_event: pe) do |a|
    a.noise_sensitivity = true
    a.sensory_needs = "May need quiet breaks during loud events"
  end
  puts "Created medical, dietary, and accessibility records"
end

puts "Seeding complete!"
