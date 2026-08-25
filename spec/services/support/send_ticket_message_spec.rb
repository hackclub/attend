require "rails_helper"

RSpec.describe Support::SendTicketMessage do
  let(:user) { User.create!(email: "agent@example.com", name: "Agent") }

  describe "WhatsApp freeform reply window" do
    let(:twilio_message) { double("Twilio message", sid: "SM999", status: "queued") }
    let(:twilio_messages) { double("Twilio messages") }

    before do
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:twilio, :account_sid).and_return("AC123")
      allow(Rails.application.credentials).to receive(:dig).with(:twilio, :auth_token).and_return("token")
      allow(twilio_messages).to receive(:create).and_return(twilio_message)
      allow(Twilio::REST::Client).to receive(:new).and_return(double("Twilio client", messages: twilio_messages))
    end

    it "refuses to send when the window has closed, without calling Twilio" do
      ticket = Ticket.create!(
        phone_number: "+14155551234",
        channel: "whatsapp",
        status: "open",
        last_inbound_at: 25.hours.ago
      )

      expect {
        described_class.call(ticket: ticket, body: "Hi there", user: user)
      }.to raise_error(described_class::DeliveryError, /24 hours/)

      expect(twilio_messages).not_to have_received(:create)
      expect(ticket.ticket_messages).to be_empty
    end

    it "sends when the contact messaged us within the last 24 hours" do
      ticket = Ticket.create!(
        phone_number: "+14155551234",
        channel: "whatsapp",
        status: "open",
        last_inbound_at: 2.hours.ago
      )

      message = described_class.call(ticket: ticket, body: "Hi there", user: user)

      expect(message.twilio_message_sid).to eq("SM999")
      expect(twilio_messages).to have_received(:create).with(hash_including(to: "whatsapp:+14155551234"))
    end

    it "does not gate SMS tickets on the window" do
      ticket = Ticket.create!(
        phone_number: "+14155551234",
        channel: "sms",
        status: "open",
        last_inbound_at: 5.days.ago
      )

      expect {
        described_class.call(ticket: ticket, body: "Hi there", user: user)
      }.not_to raise_error
    end
  end
end
