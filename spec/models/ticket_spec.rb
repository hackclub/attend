require "rails_helper"

RSpec.describe Ticket do
  describe "WhatsApp freeform reply window" do
    it "stays open for 24 hours after the last inbound message" do
      ticket = Ticket.create!(
        phone_number: "+14155551234",
        channel: "whatsapp",
        status: "open",
        last_inbound_at: 3.hours.ago
      )

      expect(ticket).to be_whatsapp_window_open
      expect(ticket).not_to be_freeform_reply_blocked
      expect(ticket.whatsapp_window_expires_at).to be_within(1.second).of(ticket.last_inbound_at + 24.hours)
    end

    it "closes once the last inbound message is more than 24 hours old" do
      ticket = Ticket.create!(
        phone_number: "+14155551234",
        channel: "whatsapp",
        status: "open",
        last_inbound_at: 25.hours.ago
      )

      expect(ticket).not_to be_whatsapp_window_open
      expect(ticket).to be_freeform_reply_blocked
    end

    it "treats a ticket with no inbound message as closed" do
      ticket = Ticket.create!(phone_number: "+14155551234", channel: "whatsapp", status: "open")

      expect(ticket.whatsapp_window_expires_at).to be_nil
      expect(ticket).to be_freeform_reply_blocked
    end

    it "does not apply to SMS or Signal tickets" do
      sms = Ticket.create!(phone_number: "+14155551234", channel: "sms", status: "open", last_inbound_at: 3.days.ago)
      signal = Ticket.create!(phone_number: "+14155555678", channel: "signal", status: "open", last_inbound_at: 3.days.ago)

      expect(sms.whatsapp_window_expires_at).to be_nil
      expect(sms).not_to be_freeform_reply_blocked
      expect(signal).not_to be_freeform_reply_blocked
    end
  end
end
