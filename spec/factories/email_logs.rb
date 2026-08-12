FactoryBot.define do
  factory :email_log do
    to_address { "recipient@example.com" }
    from_address { "sender@hackclub.com" }
    subject { "Test Email Subject" }
    mailer_class { "TestMailer" }
    mailer_action { "test_email" }
    status { "sent" }
    postmark_message_id { SecureRandom.uuid }

    trait :delivered do
      status { "delivered" }
      delivered_at { Time.current }
    end

    trait :bounced do
      status { "bounced" }
      bounced_at { Time.current }
      bounce_type { "HardBounce" }
      bounce_description { "The email account does not exist" }
    end

    trait :opened do
      status { "opened" }
      delivered_at { 1.hour.ago }
      opened_at { Time.current }
    end

    trait :failed do
      status { "failed" }
    end
  end

  factory :email_log_event do
    email_log
    event_type { "sent" }
    occurred_at { Time.current }
    metadata { {} }

    trait :delivered do
      event_type { "delivered" }
    end

    trait :bounced do
      event_type { "bounced" }
    end

    trait :opened do
      event_type { "opened" }
    end

    trait :link_clicked do
      event_type { "link_clicked" }
    end
  end
end
