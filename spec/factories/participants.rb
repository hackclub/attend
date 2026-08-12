FactoryBot.define do
  factory :participant do
    legal_first_name { "John" }
    legal_last_name { "Doe" }
    sequence(:email) { |n| "participant#{n}@example.com" }
    date_of_birth { 16.years.ago }
    phone { "+12025551234" }
  end
end
