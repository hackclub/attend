FactoryBot.define do
  factory :event_series do
    name { "Test Series #{SecureRandom.hex(4)}" }
    sequence(:slug) { |n| "test-series-#{n}" }
  end

  factory :series_api_token do
    event_series
    user
    name { "test@series-integration" }
    token_digest { Digest::SHA256.hexdigest(SecureRandom.hex(16)) }
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
