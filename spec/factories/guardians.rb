FactoryBot.define do
  factory :guardian do
    legal_first_name { "Jane" }
    legal_last_name { "Guardian" }
    sequence(:email) { |n| "guardian#{n}@example.com" }
    phone { "+12025559876" }
  end
end
