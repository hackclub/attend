FactoryBot.define do
  factory :slack_blast_recipient do
    slack_blast { nil }
    participant_event { nil }
    status { "MyString" }
    error_message { "MyText" }
    slack_message_ts { "MyString" }
  end
end
