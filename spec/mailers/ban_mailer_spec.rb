require "rails_helper"

RSpec.describe BanMailer, type: :mailer do
  describe "#upcoming_enrollments" do
    it "speaks of one person in the singular" do
      participant_event = create(:participant_event)

      mail = described_class.upcoming_enrollments(participant_events: [ participant_event ], recipients: [ "safety@example.com" ])

      expect(mail.subject).to eq("1 banned person on upcoming events")
      expect(mail.text_part.body.to_s).to include("This person is on the Attend ban list")
      expect(mail.html_part.body.to_s).to include("This person is on the Attend ban list")
    end

    it "speaks of several people in the plural" do
      participant_events = create_list(:participant_event, 2)

      mail = described_class.upcoming_enrollments(participant_events: participant_events, recipients: [ "safety@example.com" ])

      expect(mail.subject).to eq("2 banned people on upcoming events")
      expect(mail.text_part.body.to_s).to include("These people are on the Attend ban list")
    end
  end
end
