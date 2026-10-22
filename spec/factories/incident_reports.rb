FactoryBot.define do
  factory :incident_report do
    event
    reporter_name { "Sam Fictional" }
    reporter_email { "sam-fictional@example.com" }
    reporter_phone { "+14155550150" }
    reporter_role { "participant" }
    incident_type { "other" }
    priority { "s2" }
    summary { "Made-up report summary" }
    details { "Made-up report details" }
  end
end
