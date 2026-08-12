FactoryBot.define do
  factory :event do
    name { "Test Event #{SecureRandom.hex(4)}" }
    sequence(:slug) { |n| "test-event-#{n}" }
    starts_at { 1.week.from_now }
    ends_at { 2.weeks.from_now }
    registration_open_at { 1.day.ago }
    registration_close_at { 1.week.from_now }
    location_city { "San Francisco" }
    location_country { "USA" }
    location_latitude { 37.7749 }
    location_longitude { -122.4194 }
    support_email { "support@hackclub.com" }
    setup_completed_at { Time.current }

    trait :draft do
      setup_completed_at { nil }
    end
  end
end
