FactoryBot.define do
  factory :ban do
    reason { "Test ban" }
    expires_at { nil }

    transient do
      email { "banned@example.com" }
    end

    after(:build) do |ban, evaluator|
      ban.ban_emails.build(email: evaluator.email) if ban.ban_emails.empty?
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
