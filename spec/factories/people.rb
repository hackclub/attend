FactoryBot.define do
  factory :person

  factory :email_address do
    person
    sequence(:address) { |n| "address#{n}@example.com" }
    source { "participant" }

    trait :verified do
      verified_at { Time.current }
      source { "user" }
    end
  end

  factory :phone_number do
    person
    number { "+12025550143" }
    source { "participant" }
  end
end
