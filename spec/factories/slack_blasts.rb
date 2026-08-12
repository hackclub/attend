FactoryBot.define do
  factory :slack_blast do
    event { nil }
    sent_by_user { nil }
    message { "MyText" }
    status { "MyString" }
    recipient_count { 1 }
    sent_count { 1 }
    failed_count { 1 }
  end
end
