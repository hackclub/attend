require "rails_helper"

RSpec.describe MessageMailer, type: :mailer do
  describe "#broadcast" do
    it "fills in placeholders for the recipient" do
      event = create(:event, name: "Trailblazer")
      participant = create(:participant, legal_first_name: "Alexander", preferred_name: "Alex")
      message = Message.create!(event: event, audience: "confirmed_attendees", channels: %w[email],
        subject: "{{first_name}}, a note about {{event_name}}", body: "<p>Hi {{first_name}} &amp; welcome</p>",
        sent_by_user: create(:user))
      delivery = message.message_deliveries.create!(
        participant_event: create(:participant_event, event: event, participant: participant),
        channel: "email", recipient_email: participant.email
      )

      mail = described_class.broadcast(delivery: delivery)

      expect(mail.subject).to eq("Alex, a note about Trailblazer")
      expect(mail.html_part.body.decoded).to include("Hi Alex &amp; welcome")
      expect(mail.text_part.body.decoded).to include("Hi Alex & welcome")
    end
  end
end
