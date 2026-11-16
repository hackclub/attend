# Development-only: a series big enough that its dashboard is genuinely slow,
# for looking at loading states with SIMULATE_LATENCY (see
# lib/middleware/simulated_latency.rb). Every name is made up by Faker.
#
#   bin/rails dev:loading_demo          # create (or top up) the series
#   bin/rails dev:loading_demo:destroy  # remove it again
#
# The dev database is shared between checkouts, so everything this makes
# lives under one series and one email domain and is removed by :destroy.
namespace :dev do
  DEMO_SLUG = "loading-demo".freeze
  DEMO_EMAIL_DOMAIN = "loading-demo.invalid".freeze

  CITIES = [
    [ "London", "United Kingdom", 51.507, -0.128 ], [ "Berlin", "Germany", 52.52, 13.405 ],
    [ "Nairobi", "Kenya", -1.286, 36.817 ], [ "Mumbai", "India", 19.076, 72.878 ],
    [ "São Paulo", "Brazil", -23.551, -46.633 ], [ "Toronto", "Canada", 43.653, -79.383 ],
    [ "Sydney", "Australia", -33.869, 151.209 ], [ "Tokyo", "Japan", 35.676, 139.65 ],
    [ "Lagos", "Nigeria", 6.524, 3.379 ], [ "Mexico City", "Mexico", 19.433, -99.133 ],
    [ "Seattle", "United States", 47.606, -122.332 ], [ "Austin", "United States", 30.267, -97.743 ],
    [ "Boston", "United States", 42.36, -71.059 ], [ "Singapore", "Singapore", 1.352, 103.82 ],
    [ "Dublin", "Ireland", 53.35, -6.26 ], [ "Kraków", "Poland", 50.065, 19.945 ]
  ].freeze

  desc "Create a large fictional series for testing loading states"
  task loading_demo: :environment do
    abort "development only" unless Rails.env.development?

    require "factory_bot_rails"
    require "faker"

    events = ENV.fetch("EVENTS", 30).to_i
    per_event = ENV.fetch("PER_EVENT", 80).to_i

    series = EventSeries.find_or_create_by!(slug: DEMO_SLUG) do |s|
      s.name = "Loading demo"
      s.description = "Fictional data for testing loading states."
    end

    statuses = %w[invited in_progress in_progress awaiting_guardian complete complete complete withdrawn]
    created = 0

    events.times do |i|
      city, country, lat, lng = CITIES[i % CITIES.length]
      slug = "#{DEMO_SLUG}-#{i + 1}"
      starts = (i - 4).weeks.from_now

      event = Event.find_by(slug: slug) || FactoryBot.create(:event,
        slug: slug, name: "#{city} Hack #{i + 1}", event_series: series,
        location_city: city, location_country: country,
        location_latitude: lat, location_longitude: lng,
        starts_at: starts, ends_at: starts + 2.days)

      (per_event - event.participant_events.count).times do |n|
        participant = Participant.create!(
          legal_first_name: Faker::Name.first_name,
          legal_last_name: Faker::Name.last_name,
          email: "p#{i}-#{n}-#{SecureRandom.hex(3)}@#{DEMO_EMAIL_DOMAIN}",
          date_of_birth: rand(14..17).years.ago - rand(0..300).days
        )
        ParticipantEvent.create!(participant: participant, event: event, status: statuses.sample, onboarding_step: rand(0..6))
        created += 1
      end
      print "."
    end

    puts "\n#{series.name}: #{series.events.count} events, #{created} registrations added. /admin/series/#{DEMO_SLUG}"
  end

  namespace :loading_demo do
    desc "Remove the loading-states demo series"
    task destroy: :environment do
      abort "development only" unless Rails.env.development?

      series = EventSeries.find_by(slug: DEMO_SLUG)
      Participant.where("email LIKE ?", "%@#{DEMO_EMAIL_DOMAIN}").find_each(&:destroy!)
      series&.events&.each(&:destroy!)
      series&.destroy!
      puts "Removed."
    end
  end
end
