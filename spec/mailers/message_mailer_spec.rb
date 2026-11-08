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

    it "shows uploaded images from this app" do
      event = create(:event)
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture("headshot.png").open, filename: "map.png",
        metadata: { Message::IMAGE_EVENT_KEY => event.id })
      src = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
      message = Message.create!(event: event, audience: "confirmed_attendees", channels: %w[email],
        body: %(<p>Map:</p><img src="#{src}" alt="Venue map">), sent_by_user: create(:user))
      participant = create(:participant)
      delivery = message.message_deliveries.create!(
        participant_event: create(:participant_event, event: event, participant: participant),
        channel: "email", recipient_email: participant.email
      )

      html = described_class.broadcast(delivery: delivery).html_part.body.decoded

      expect(html).to match(%r{<img src="http://example\.com/rails/active_storage/representations/[^"]+" alt="Venue map"})
    end
  end
end
