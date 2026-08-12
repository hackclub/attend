FactoryBot.define do
  factory :group do
    event
    sequence(:name) { |n| "Group #{n}" }
    color { "#ec3750" }
  end

  factory :group_membership do
    group
    participant_event
  end
end
