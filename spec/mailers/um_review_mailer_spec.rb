require "rails_helper"

RSpec.describe UmReviewMailer, type: :mailer do
  describe "#review_request" do
    let(:participant_event) { create(:participant_event) }

    before do
      participant_event.travels.create!(direction: "inbound", mode: "plane", is_unaccompanied_minor: true)
    end

    it "emails the reviewer with a link to the admin travel page" do
      mail = described_class.review_request(participant_event: participant_event)

      expect(mail.to).to eq([ "leo@hackclub.com" ])
      expect(mail.subject).to include("Review a new UM flight status")
      expect(mail.subject).to include(participant_event.participant.display_name)
      expect(mail.body.encoded).to include("unaccompanied minor")
      expect(mail.body.encoded).to include("/admin/events/#{participant_event.event.slug}/participants/#{participant_event.id}/travel")
    end
  end
end
