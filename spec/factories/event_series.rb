FactoryBot.define do
  factory :event_series do
    name { "Test Series #{SecureRandom.hex(4)}" }
    sequence(:slug) { |n| "test-series-#{n}" }
  end

  factory :series_role_assignment do
    user
    event_series
    role { "organizer" }

    trait :owner do
      role { "owner" }
    end
  end
end
