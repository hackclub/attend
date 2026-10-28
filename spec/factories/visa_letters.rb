FactoryBot.define do
  factory :visa_letter_template do
    name { "Default visa letter" }
    body do
      <<~BODY
        To Whom It May Concern,

        The Hack Foundation, doing business as Hack Club, confirms that {{participant_full_name}} has been invited to attend {{event_name}} from {{event_date_range}} in {{event_city}}, {{event_country}}.

        Reference Number: {{reference_number}}
      BODY
    end
    signatory_name { "Fictional Signatory" }
    signatory_title { "Executive Director" }
    is_default { false }
    active { true }

    trait :default do
      is_default { true }
      event { nil }
    end
  end

  factory :visa_letter_invitation do
    event
    sequence(:email) { |n| "visa-invitee#{n}@example.com" }
  end

  factory :visa_letter_application do
    event
    user
    full_name { "Ada Example" }
    email { user&.email || "applicant@example.com" }
    date_of_birth { Date.new(2008, 4, 1) }
    nationality { "Exampleland" }
    place_of_birth { "Example City" }
    phone { "+12025550123" }
    address { "2 Sample Road, Example City, Exampleland" }

    trait :imported do
      user { nil }
      imported_at { Time.current }
      place_of_birth { nil }
      phone { nil }
      address { nil }
    end
  end
end
