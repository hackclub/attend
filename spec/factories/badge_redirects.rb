FactoryBot.define do
  factory :badge_redirect do
    sequence(:slack_id) { |n| "U0BADGE#{n}" }
    url { "https://example.com" }
  end
end
