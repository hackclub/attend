require "rails_helper"

RSpec.describe ParticipantMailer, type: :mailer do
  describe "#invitation" do
    it "replies to the event's configured support email" do
      event = create(:event, support_email: "organizers@hackclub.com")

      mail = described_class.invitation(
        email: "participant@example.com",
        event: event
      )

      expect(mail.reply_to).to eq([ "organizers@hackclub.com" ])
    end
  end
end
