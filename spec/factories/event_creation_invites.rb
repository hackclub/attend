FactoryBot.define do
  factory :event_creation_invite do
    sequence(:email) { |n| "organizer#{n}@example.com" }
    association :invited_by, factory: :user

    trait :accepted do
      accepted_at { Time.current }
      accepted_by { User.find_by(email: email) || association(:user, email: email) }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end

    trait :revoked do
      revoked_at { Time.current }
    end
  end
end
