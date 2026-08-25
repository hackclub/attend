require "rails_helper"

RSpec.describe Support::RecordAutomatedSms do
  let(:phone) { "+14155551234" }

  it "creates a log with the normalized phone number" do
    log = described_class.call(phone: "(415) 555-1234", body: "Hello", twilio_sid: "SM100", source: "Incident reports")

    expect(log.phone_number).to eq(phone)
    expect(log.body).to eq("Hello")
    expect(log.twilio_sid).to eq("SM100")
    expect(log.source).to eq("Incident reports")
    expect(log.sent_at).to be_present
  end

  it "returns nil for an invalid phone number" do
    expect(described_class.call(phone: "not a phone", body: "Hello")).to be_nil
    expect(AutomatedSmsLog.count).to eq(0)
  end

  context "when the recipient has an open SMS ticket" do
    let!(:ticket) { Ticket.create!(phone_number: phone, channel: "sms", status: "open") }

    it "appends an automated message to the ticket thread" do
      described_class.call(phone: phone, body: "Your event starts soon", twilio_sid: "SM101", source: "Broadcast message")

      message = ticket.ticket_messages.sole
      expect(message).to be_outbound
      expect(message).to be_automated
      expect(message.body).to eq("Your event starts soon")
      expect(message.user).to be_nil
      expect(message.twilio_message_sid).to eq("SM101")
      expect(message.automated_source).to eq("Broadcast message")
      expect(ticket.reload.last_message_at).to be_present
    end

    it "does not append when the open ticket is on another channel" do
      ticket.update!(channel: "whatsapp")

      described_class.call(phone: phone, body: "Hello", twilio_sid: "SM102")

      expect(ticket.ticket_messages.count).to eq(0)
      expect(AutomatedSmsLog.count).to eq(1)
    end

    it "does not append when the ticket is closed" do
      ticket.update!(status: "closed")

      described_class.call(phone: phone, body: "Hello", twilio_sid: "SM103")

      expect(ticket.ticket_messages.count).to eq(0)
      expect(AutomatedSmsLog.count).to eq(1)
    end
  end

  it "still creates the log when no ticket exists" do
    described_class.call(phone: phone, body: "Hello", twilio_sid: "SM104")

    expect(AutomatedSmsLog.count).to eq(1)
    expect(TicketMessage.count).to eq(0)
  end
end
