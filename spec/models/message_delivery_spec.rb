require "rails_helper"

RSpec.describe MessageDelivery do
  describe "#recipient_name" do
    it "falls back to a guardian's full name" do
      delivery = described_class.new(
        guardian: build(:guardian, legal_first_name: "Jane", legal_last_name: "Guardian"),
        channel: "email",
        recipient_email: "guardian@example.com"
      )

      expect(delivery.recipient_name).to eq("Jane Guardian")
    end

    it "prefers a participant's display name" do
      delivery = described_class.new(
        participant_event: build(:participant_event, participant: build(:participant, preferred_name: "Johnny")),
        channel: "email",
        recipient_email: "participant@example.com"
      )

      expect(delivery.recipient_name).to eq("Johnny")
    end

    it "falls back to the recipient email when there is no recipient record" do
      delivery = described_class.new(channel: "email", recipient_email: "nobody@example.com")

      expect(delivery.recipient_name).to eq("nobody@example.com")
    end
  end
end
