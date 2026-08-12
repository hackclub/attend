FactoryBot.define do
  factory :consent do
    participant_event
    consent_type { :waiver }
    status { :pending }

    trait :freedom_waiver do
      consent_type { :freedom_waiver }
    end

    trait :signed do
      status { :signed }
      signed_at { Time.current }
    end

    trait :custom_document do
      consent_type { :custom_document }
      custom_document
    end
  end
end
