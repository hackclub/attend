# Builds a large, fictional, day-of event for checking that admin pages stay fast:
# 500 registrations (mostly minors with guardians), scan points of every sort and
# about 10,000 scans over the event's first four days.
#
#   bin/rails dev:perf_event          creates "Perf 500" (slug perf-500)
#   RESET=1 bin/rails dev:perf_event  deletes it first and builds it again
#   bin/rails dev:perf_timings        times the admin pages on it
#
# Development only. Every name, email and phone number is made up.
namespace :dev do
  PERF_SLUG = "perf-500".freeze

  desc "Create the 500-participant performance event (development only)"
  task perf_event: :environment do
    abort "dev:perf_event only runs in development" unless Rails.env.development?

    if (existing = Event.find_by(slug: PERF_SLUG))
      abort "#{PERF_SLUG} already exists. Run with RESET=1 to rebuild it." unless ENV["RESET"] == "1"
      puts "Deleting #{PERF_SLUG}..."
      existing.update_columns(hotel_scan_context_id: nil)
      existing.destroy!
    end

    ActiveJob::Base.queue_adapter = :test
    random = Random.new(500)
    admin = User.find_by!(email: "admin@hackclub.com")
    now = Time.current

    event = Event.create!(
      slug: PERF_SLUG,
      name: "Perf 500",
      support_email: "perf-support@events.hackclub.com",
      timezone: "Eastern Time (US & Canada)",
      starts_at: (now - 4.days).change(hour: 9),
      ends_at: (now + 1.day).change(hour: 17),
      config: { "groups_enabled" => true, "accommodation_enabled" => true, "travel_enabled" => true }
    )
    EventRoleAssignment.find_or_create_by!(event: event, user: admin, role: "event_admin")

    entrance = event.scan_contexts.first
    entrance.update!(name: "Main entrance")
    points = {
      entrance: entrance,
      pickup: event.scan_contexts.create!(name: "Airport pickup", is_travel_pickup: true, checks_in: false, position: 1),
      hotel: event.scan_contexts.create!(name: "Hotel", checks_in: false, is_travel_pickup: false, position: 2),
      lunch: event.scan_contexts.create!(name: "Lunch", checks_in: false, is_travel_pickup: false, position: 3),
      dinner: event.scan_contexts.create!(name: "Dinner", checks_in: false, is_travel_pickup: false, position: 4),
      swag: event.scan_contexts.create!(name: "Swag pickup", checks_in: false, is_travel_pickup: false, position: 5),
      workshop: event.scan_contexts.create!(name: "Workshop", checks_in: false, is_travel_pickup: false, position: 6),
      bus_tour: event.scan_contexts.create!(name: "Bus tour", checks_in: false, is_travel_pickup: false, position: 7),
      free_time: event.scan_contexts.create!(name: "Free time out", checks_in: false, is_travel_pickup: false, position: 8),
      departure: event.scan_contexts.create!(name: "Departure", checks_in: false, is_travel_pickup: false, position: 9)
    }
    event.update_columns(hotel_scan_context_id: points[:hotel].id)

    groups = ("A".."J").map.with_index do |letter, i|
      event.groups.create!(name: "Group #{letter}", slug: "group-#{letter.downcase}", position: i)
    end

    first_names = %w[Ada Bo Cam Dev Eli Fern Gus Hana Ines Jo Kai Lior Mae Noor Oli Pia Quin Rae Sol Tao Uma Vic Wren Xan Yuki Zed]
    last_names = %w[Abbot Brook Chen Diaz Eko Ford Gray Hale Ito Jansen Khan Lund Mora Nash Okafor Park Quist Reyes Sato Tran Ueda Vance Wolfe Yang Zhou]
    statuses = %w[complete complete complete complete complete complete in_progress awaiting_guardian invited withdrawn]

    print "Registrations"
    registrations = 500.times.map do |i|
      minor = i % 5 != 0
      age = minor ? random.rand(13..17) : 18
      participant = Participant.create!(
        email: "perf-#{i}@example.com",
        legal_first_name: first_names[i % first_names.size],
        legal_last_name: "#{last_names[(i / first_names.size) % last_names.size]}-#{i}",
        date_of_birth: event.ends_at.to_date - age.years - random.rand(30..300).days,
        pronouns: %w[she/her he/him they/them].sample(random: random)
      )
      status = statuses[i % statuses.size]
      registration = ParticipantEvent.create!(
        participant: participant, event: event, status: status, onboarding_step: 8,
        code_of_conduct_accepted_at: (status.in?(%w[complete awaiting_guardian withdrawn]) ? now - 30.days : nil)
      )
      registration.create_medical!(section_response: "nothing_to_add")
      registration.create_dietary!(section_response: "nothing_to_add")
      registration.create_accessibility!(section_response: "nothing_to_add")
      if status.in?(%w[complete awaiting_guardian withdrawn])
        registration.travels.create!(direction: "inbound", mode: "plane", arrival_time: event.starts_at - 3.hours)
        registration.travels.create!(direction: "outbound", mode: "plane", departure_time: event.ends_at + 3.hours)
        registration.create_accommodation!(check_in_date: event.starts_at.to_date, check_out_date: event.ends_at.to_date)
      end
      if status.in?(%w[complete withdrawn])
        registration.consents.create!(consent_type: "waiver", status: "signed", signed_at: now - 20.days)
      end
      if minor
        guardian = Guardian.create!(email: "perf-guardian-#{i}@example.com", legal_first_name: "Parent", legal_last_name: "Of #{i}")
        registration.guardian_participant_events.create!(guardian: guardian, status: status == "complete" ? "completed" : "pending")
      else
        registration.emergency_contacts.create!(name: "Contact #{i}", phone: "+1415555#{format('%04d', 100 + (i % 100))}")
      end
      registration.group_memberships.create!(group: groups[i % groups.size])
      print "." if (i % 50).zero?
      registration
    end
    puts

    print "Scans"
    attending = registrations.reject { |r| r.withdrawn? || r.invited? }
    rows = []
    add = ->(registration, point, at) {
      rows << { id: SecureRandom.uuid, participant_event_id: registration.id, scan_context_id: point.id, user_id: admin.id,
                scanned_at: at, source: "qr", created_at: at, updated_at: at }
    }
    attending.each do |registration|
      day0 = event.starts_at.beginning_of_day
      add.(registration, points[:pickup], day0 - 2.hours + random.rand(0..300).minutes) if random.rand < 0.6
      4.times do |d|
        day = day0 + d.days
        next if day + 8.hours > now
        add.(registration, points[:hotel], day - 1.day + 21.hours + random.rand(0..90).minutes) if random.rand < 0.5
        add.(registration, points[:entrance], day + 8.hours + random.rand(0..90).minutes)
        add.(registration, points[:workshop], day + 10.hours + random.rand(0..60).minutes) if random.rand < 0.7
        add.(registration, points[:lunch], day + 12.hours + random.rand(0..45).minutes)
        if d == 1
          add.(registration, points[:bus_tour], day + 13.hours + random.rand(0..20).minutes)
          add.(registration, points[:entrance], day + 16.hours + random.rand(0..30).minutes)
        end
        add.(registration, points[:free_time], day + 14.hours + random.rand(0..60).minutes) if random.rand < 0.3
        add.(registration, points[:entrance], day + 15.hours + random.rand(0..60).minutes) if random.rand < 0.6
        add.(registration, points[:swag], day + 16.hours + random.rand(0..60).minutes) if random.rand < 0.5
        add.(registration, points[:dinner], day + 18.hours + random.rand(0..45).minutes)
        add.(registration, points[:swag], day + 19.hours + random.rand(0..60).minutes) if d.zero?
      end
    end
    rows.select! { |row| row[:scanned_at] <= now }
    rows.each_slice(2_000) { |slice| Scan.insert_all!(slice); print "." }
    puts

    puts "Built #{PERF_SLUG}: #{registrations.size} registrations, #{rows.size} scans, #{points.size} scan points."
    puts "Open /admin/#{PERF_SLUG} on this checkout's dev server."
  end

  desc "Time the admin pages on the performance event (development only)"
  task perf_timings: :environment do
    abort "dev:perf_timings only runs in development" unless Rails.env.development?

    event = Event.find_by!(slug: PERF_SLUG)
    admin = User.find_by!(email: "admin@hackclub.com")
    registration = event.participant_events.joins(:participant).order("participants.legal_last_name").first
    pages = {
      "Dashboard" => "/admin/#{event.slug}",
      "Participants list" => "/admin/events/#{event.slug}/participants",
      "Participants table" => "/admin/events/#{event.slug}/participants/table",
      "Participant" => "/admin/events/#{event.slug}/participants/#{registration.id}",
      "Scanner" => "/admin/events/#{event.slug}/scans/scanner",
      "Scans" => "/admin/events/#{event.slug}/scans",
      "Scan history" => "/admin/events/#{event.slug}/scans/history",
      "Scan points" => "/admin/events/#{event.slug}/scan_contexts"
    }

    original_console = admin.admin_console_beta
    # The integration session posts no CSRF token, so the dev sign-in form needs forgery protection off here.
    ActionController::Base.allow_forgery_protection = false
    app = ActionDispatch::Integration::Session.new(Rails.application)
    app.host! "localhost"
    runs = Integer(ENV.fetch("RUNS", "5"))

    { "Original admin" => false, "Console beta" => true }.each do |ui, console|
      admin.update_columns(admin_console_beta: console)
      app.post "/dev_sign_in", params: { email: admin.email }
      puts "\n#{ui} (median of #{runs} runs, after one warm-up)"
      pages.each do |name, path|
        app.get path
        status = app.response.status
        times = runs.times.map do
          queries = 0
          counter = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
          ms = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            app.get path
            (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
          end
          [ ms, queries ]
        end
        ms = times.map(&:first).sort[runs / 2]
        puts format("  %-20s %6.0f ms  %5d queries  HTTP %d%s", name, ms, times.last.last, status, status == 200 ? "" : " -> #{app.response.location}")
      end
    end
  ensure
    admin&.update_columns(admin_console_beta: original_console) unless original_console.nil?
  end
end
