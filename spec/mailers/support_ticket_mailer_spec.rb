require "rails_helper"

RSpec.describe SupportTicketMailer, type: :mailer do
  let(:ticket) { Ticket.create!(channel: "sms", phone_number: "+14155550101", status: "open") }
  let(:message) { TicketMessage.create!(ticket: ticket, direction: "inbound", channel: "sms", body: "Help please", sent_at: Time.current) }

  describe "#new_chat" do
    it "sends nothing when no addresses are configured" do
      mail = described_class.new_chat(ticket_id: ticket.id, message_id: message.id)

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "sends to every configured address" do
      Setting.support_email_notification_addresses = [ "first@example.com", "second@example.com" ]

      mail = described_class.new_chat(ticket_id: ticket.id, message_id: message.id)

      expect(mail.to).to eq([ "first@example.com", "second@example.com" ])
      expect(mail.subject).to include("+14155550101")
    end
  end
end
