FactoryBot.define do
  factory :event_role_assignment do
    user
    event
    role { "ops" }
  end
end
