FactoryBot.define do
  factory :invitation do
    sequence(:email) { |n| "invited#{n}@example.com" }
    event
    token { SecureRandom.urlsafe_base64(32) }
    expires_at { 30.days.from_now }
    accepted_at { nil }

    trait :accepted do
      accepted_at { Time.current }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
