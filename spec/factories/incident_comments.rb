FactoryBot.define do
  factory :incident_comment do
    incident { nil }
    user { nil }
    body { "MyText" }
    new_status { "MyString" }
  end
end
