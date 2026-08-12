require "rails_helper"

RSpec.describe Support::ProcessIncomingTwilioMessage do
  describe "SMS notifications" do
    include ActiveJob::TestHelper

    let(:payload) do
      {
        "From" => "whatsapp:+14155551234",
        "To" => "whatsapp:+18556254225",
        "Body" => "Hello there",
        "MessageSid" => "SM123",
        "NumMedia" => "0"
      }
    end

    it "enqueues a new_ticket notification when the message opens a new ticket" do
      expect {
        described_class.call(payload)
      }.to have_enqueued_job(SendSupportTicketSmsNotificationJob).with(anything, "new_ticket")
    end

    it "does not enqueue a new_ticket notification for messages on an existing open ticket" do
      Ticket.create!(phone_number: "+14155551234", channel: "whatsapp", status: "open")

      expect {
        described_class.call(payload)
      }.not_to have_enqueued_job(SendSupportTicketSmsNotificationJob).with(anything, "new_ticket")
    end

    it "enqueues an assigned_reply notification when the ticket is assigned" do
      user = User.create!(email: "assigned-inbound@example.com", name: "Assignee")
      Ticket.create!(phone_number: "+14155551234", channel: "whatsapp", status: "open", assigned_to: user)

      expect {
        described_class.call(payload)
      }.to have_enqueued_job(SendSupportTicketSmsNotificationJob).with(anything, "assigned_reply")
    end
  end

  describe "#attach_media" do
    it "skips invalid media URLs before creating an HTTP client" do
      payload = {
        "NumMedia" => "1",
        "MediaUrl0" => "http://169.254.169.254/latest/meta-data/",
        "MediaContentType0" => "image/jpeg"
      }
      message = instance_double(TicketMessage)

      expect(Faraday).not_to receive(:new)

      described_class.new(payload).send(:attach_media, message)
    end
  end

  describe "#valid_twilio_media_url?" do
    subject(:service) { described_class.new({}) }

    it "allows HTTPS Twilio media API URLs" do
      expect(service.send(:valid_twilio_media_url?, "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM123/Media/ME123")).to be(true)
    end

    it "allows HTTPS Twilio media API subdomains" do
      expect(service.send(:valid_twilio_media_url?, "https://edge.api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM123/Media/ME123")).to be(true)
    end

    it "rejects non-HTTPS URLs" do
      expect(service.send(:valid_twilio_media_url?, "http://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM123/Media/ME123")).to be(false)
    end

    it "rejects non-Twilio hosts" do
      expect(service.send(:valid_twilio_media_url?, "https://api.twilio.com.evil.example/media")).to be(false)
    end

    it "rejects malformed URLs" do
      expect(service.send(:valid_twilio_media_url?, "https://api.twilio.com/%zz")).to be(false)
    end
  end
end
