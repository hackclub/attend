FactoryBot.define do
  factory :guardian_participant_event do
    guardian
    participant_event
    status { :pending }
  end
end
