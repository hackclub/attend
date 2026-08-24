FactoryBot.define do
  factory :guardian_participant_event do
    guardian
    participant_event
    status { :pending }
    # A guardian who can reach the portal has, by definition, been sent a link.
    # An invite with no send stamp is treated as revoked, so leaving this nil by
    # default would 404 every portal spec.
    invite_token_sent_at { Time.current }

    trait :never_sent do
      invite_token_sent_at { nil }
    end
  end
end
