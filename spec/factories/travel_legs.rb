FactoryBot.define do
  factory :travel_leg do
    travel { nil }
    position { 1 }
    flight_code { "MyString" }
    departure_airport { "MyString" }
    arrival_airport { "MyString" }
    departure_time { "2025-11-30 22:53:36" }
    arrival_time { "2025-11-30 22:53:36" }
    confirmation_code { "MyString" }
  end
end
