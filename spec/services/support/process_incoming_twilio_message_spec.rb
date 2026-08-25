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

  describe "automated message backfill" do
    let(:phone) { "+14155551234" }
    let(:sms_payload) do
      {
        "From" => phone,
        "To" => "+18556254225",
        "Body" => "Ok twin",
        "MessageSid" => "SM_INBOUND",
        "NumMedia" => "0"
      }
    end

    def create_log(body:, sid:, sent_at: 1.hour.ago, source: nil)
      AutomatedSmsLog.create!(phone_number: phone, body: body, twilio_sid: sid, sent_at: sent_at, source: source)
    end

    it "backfills recent automated texts into a newly created ticket, before the reply" do
      create_log(body: "Your event starts at 9am", sid: "SM_AUTO_1", source: "Broadcast message")

      ticket = described_class.call(sms_payload)

      messages = ticket.ticket_messages.order(created_at: :asc)
      expect(messages.map(&:body)).to eq([ "Your event starts at 9am", "Ok twin" ])
      expect(messages.first).to be_automated
      expect(messages.first).to be_outbound
      expect(messages.first.automated_source).to eq("Broadcast message")
    end

    it "skips logs older than the backfill window" do
      create_log(body: "Ancient text", sid: "SM_OLD", sent_at: 8.days.ago)

      ticket = described_class.call(sms_payload)

      expect(ticket.ticket_messages.map(&:body)).to eq([ "Ok twin" ])
    end

    it "skips logs already shown in another ticket" do
      log = create_log(body: "Already seen", sid: "SM_SEEN")
      old_ticket = Ticket.create!(phone_number: phone, channel: "sms", status: "closed")
      TicketMessage.create!(ticket: old_ticket, direction: "outbound", channel: "sms",
                            automated: true, body: log.body, twilio_message_sid: log.twilio_sid, sent_at: log.sent_at)

      ticket = described_class.call(sms_payload)

      expect(ticket).not_to eq(old_ticket)
      expect(ticket.ticket_messages.map(&:body)).to eq([ "Ok twin" ])
    end

    it "does not backfill into an existing open ticket" do
      existing = Ticket.create!(phone_number: phone, channel: "sms", status: "open")
      create_log(body: "New automated text", sid: "SM_AUTO_2")

      ticket = described_class.call(sms_payload)

      expect(ticket).to eq(existing)
      expect(ticket.ticket_messages.map(&:body)).to eq([ "Ok twin" ])
    end

    it "does not backfill SMS logs into a new whatsapp ticket" do
      create_log(body: "SMS only", sid: "SM_AUTO_3")
      whatsapp_payload = sms_payload.merge("From" => "whatsapp:#{phone}", "To" => "whatsapp:+18556254225")

      ticket = described_class.call(whatsapp_payload)

      expect(ticket.channel).to eq("whatsapp")
      expect(ticket.ticket_messages.map(&:body)).to eq([ "Ok twin" ])
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
