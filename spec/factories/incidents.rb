FactoryBot.define do
  factory :incident do
    event
    association :reported_by, factory: :user
    category { "behavior" }
    severity { "low" }
    summary { "Made-up summary" }
    details { "Made-up details" }
    visible_to_roles { %w[event_admin safeguarding_lead] }
  end
end
