FactoryBot.define do
  factory :guardian do
    legal_first_name { "Jane" }
    legal_last_name { "Guardian" }
    sequence(:email) { |n| "guardian#{n}@example.com" }
    phone { "+12025559876" }

    trait :with_address do
      address_line_1 { "1 Example Street" }
      city { "Springfield" }
      state { "VT" }
      postal_code { "05001" }
      country { "US" }
    end
  end
end
