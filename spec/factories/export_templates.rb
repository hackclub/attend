FactoryBot.define do
  factory :export_template do
    event
    created_by factory: :user
    sequence(:name) { |n| "Template #{n}" }
    columns { [ "participant.email", "participant_event.status" ] }
    filters { [] }
    row_mode { "participant" }
  end
end
