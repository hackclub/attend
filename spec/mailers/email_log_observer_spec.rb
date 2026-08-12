require "rails_helper"

RSpec.describe EmailLogObserver do
  describe ".delivered_email" do
    let(:message) do
      mail = Mail.new do
        from "sender@hackclub.com"
        to "recipient@example.com"
        subject "Test Subject"
      end
      mail.instance_variable_set(:@_mailer_action, "test_action")
      mail.delivery_handler = ApplicationMailer
      mail
    end

    before do
      message.perform_deliveries = true
    end

    it "creates an EmailLog record" do
      expect {
        EmailLogObserver.delivered_email(message)
      }.to change(EmailLog, :count).by(1)

      log = EmailLog.last
      expect(log.to_address).to eq("recipient@example.com")
      expect(log.from_address).to eq("sender@hackclub.com")
      expect(log.subject).to eq("Test Subject")
      expect(log.status).to eq("sent")
    end

    it "creates a sent event" do
      expect {
        EmailLogObserver.delivered_email(message)
      }.to change(EmailLogEvent, :count).by(1)

      event = EmailLogEvent.last
      expect(event.event_type).to eq("sent")
      expect(event.occurred_at).to be_present
    end

    it "does nothing when perform_deliveries is false" do
      message.perform_deliveries = false

      expect {
        EmailLogObserver.delivered_email(message)
      }.not_to change(EmailLog, :count)
    end

    it "extracts postmark message ID from X-PM-Message-Id header" do
      message["X-PM-Message-Id"] = "postmark-uuid-123"

      EmailLogObserver.delivered_email(message)

      log = EmailLog.last
      expect(log.postmark_message_id).to eq("postmark-uuid-123")
    end

    it "falls back to Message-ID header if X-PM-Message-Id is not present" do
      message["Message-ID"] = "<fallback-id@example.com>"

      EmailLogObserver.delivered_email(message)

      log = EmailLog.last
      expect(log.postmark_message_id).to eq("<fallback-id@example.com>")
    end

    it "handles multiple recipients" do
      message.to = [ "one@example.com", "two@example.com" ]

      EmailLogObserver.delivered_email(message)

      log = EmailLog.last
      expect(log.to_address).to eq("one@example.com, two@example.com")
    end

    it "rescues and logs errors without raising" do
      allow(EmailLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(EmailLog.new))

      expect(Rails.logger).to receive(:error).with(/Failed to log email/)

      expect {
        EmailLogObserver.delivered_email(message)
      }.not_to raise_error
    end

    it "reports errors to Sentry when available" do
      allow(EmailLog).to receive(:create!).and_raise(StandardError.new("test error"))
      sentry_double = class_double("Sentry", capture_exception: nil).as_stubbed_const

      expect(sentry_double).to receive(:capture_exception)

      EmailLogObserver.delivered_email(message)
    end
  end

  describe ".extract_mailer_info" do
    it "extracts mailer class and action from message" do
      message = Mail.new
      message.delivery_handler = ApplicationMailer
      message.instance_variable_set(:@_mailer_action, "welcome_email")

      mailer_class, mailer_action = EmailLogObserver.extract_mailer_info(message)

      expect(mailer_class).to eq("ApplicationMailer")
      expect(mailer_action).to eq("welcome_email")
    end

    it "returns 'unknown' for missing mailer action" do
      message = Mail.new
      message.delivery_handler = ApplicationMailer

      _, mailer_action = EmailLogObserver.extract_mailer_info(message)

      expect(mailer_action).to eq("unknown")
    end
  end

  describe ".extract_postmark_message_id" do
    it "prefers X-PM-Message-Id header" do
      message = Mail.new
      message["X-PM-Message-Id"] = "pm-123"
      message["Message-ID"] = "<fallback@example.com>"

      result = EmailLogObserver.extract_postmark_message_id(message)

      expect(result).to eq("pm-123")
    end

    it "falls back to Message-ID" do
      message = Mail.new
      message["Message-ID"] = "<fallback@example.com>"

      result = EmailLogObserver.extract_postmark_message_id(message)

      expect(result).to eq("<fallback@example.com>")
    end

    it "returns nil when no message ID headers present" do
      message = Mail.new

      result = EmailLogObserver.extract_postmark_message_id(message)

      expect(result).to be_nil
    end
  end
end
