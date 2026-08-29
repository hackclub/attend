require "rails_helper"

RSpec.describe SendSupportTicketSmsNotificationJob do
  let(:twilio) { instance_double(TwilioService) }
  let(:assignee) { User.create!(email: "assignee-sms@example.com", name: "Assignee", phone_number: "+14155550190") }
  let(:ticket) { Ticket.create!(channel: "whatsapp", phone_number: "+14155550111", status: "open") }
  let(:message) do
    TicketMessage.create!(ticket: ticket, direction: "inbound", channel: "whatsapp", body: "Help please", sent_at: Time.current)
  end

  before do
    allow(TwilioService).to receive(:new).and_return(twilio)
    allow(twilio).to receive(:send_sms)
    Setting.support_sms_notifications_enabled = true
    Setting.support_sms_notification_numbers = [ "+14155551234", "+447911123456" ]
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  describe "new_ticket" do
    it "texts every configured number" do
      described_class.perform_now(message.id, "new_ticket")

      expect(twilio).to have_received(:send_sms).with(to: "+14155551234", body: a_string_including("+14155550111", "Help please"), source: "Staff notifications")
      expect(twilio).to have_received(:send_sms).with(to: "+447911123456", body: a_string_including("WhatsApp"), source: "Staff notifications")
    end

    it "sends nothing when the feature is disabled" do
      Setting.support_sms_notifications_enabled = false

      described_class.perform_now(message.id, "new_ticket")

      expect(twilio).not_to have_received(:send_sms)
    end

    it "survives a Twilio error on one number and continues to the next" do
      allow(twilio).to receive(:send_sms).with(to: "+14155551234", body: anything, source: anything).and_raise(TwilioService::Error, "boom")

      expect { described_class.perform_now(message.id, "new_ticket") }.not_to raise_error
      expect(twilio).to have_received(:send_sms).with(to: "+447911123456", body: anything, source: anything)
    end
  end

  describe "assigned_reply" do
    before { ticket.update!(assigned_to: assignee) }

    it "texts the assignee's phone" do
      described_class.perform_now(message.id, "assigned_reply")

      expect(twilio).to have_received(:send_sms).with(to: "+14155550190", body: a_string_including("new reply"), source: "Staff notifications")
    end

    it "skips when the assignee has no phone" do
      assignee.update!(phone_number: nil)

      described_class.perform_now(message.id, "assigned_reply")

      expect(twilio).not_to have_received(:send_sms)
    end

    it "throttles to one text per ticket per window" do
      described_class.perform_now(message.id, "assigned_reply")
      second = TicketMessage.create!(ticket: ticket, direction: "inbound", channel: "whatsapp", body: "Another", sent_at: Time.current)
      described_class.perform_now(second.id, "assigned_reply")

      expect(twilio).to have_received(:send_sms).once
    end

    it "sends again once the throttle window has passed" do
      described_class.perform_now(message.id, "assigned_reply")
      Rails.cache.clear
      second = TicketMessage.create!(ticket: ticket, direction: "inbound", channel: "whatsapp", body: "Another", sent_at: Time.current)
      described_class.perform_now(second.id, "assigned_reply")

      expect(twilio).to have_received(:send_sms).twice
    end
  end
end
