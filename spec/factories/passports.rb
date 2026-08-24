FactoryBot.define do
  factory :passport do
    association :user

    trait :active do
      paired_at { Time.current }
      association :paired_by, factory: :user
    end

    trait :revoked do
      active
      revoked_at { Time.current }
      association :revoked_by, factory: :user
    end
  end
end
