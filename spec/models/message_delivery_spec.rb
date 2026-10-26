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

  describe "#recipient_identifier" do
    it "names the app account a push goes to" do
      user = build(:user, email: "app-user@example.com")
      delivery = described_class.new(
        participant_event: build(:participant_event, participant: build(:participant, user: user)),
        channel: "push"
      )

      expect(delivery.recipient_identifier).to eq("app-user@example.com")
    end

    it "falls back to a generic label for a push without an account" do
      delivery = described_class.new(participant_event: build(:participant_event), channel: "push")

      expect(delivery.recipient_identifier).to eq("App")
    end

    it "uses the channel's address otherwise" do
      delivery = described_class.new(channel: "sms", recipient_phone: "+12025550100", recipient_email: "x@example.com")

      expect(delivery.recipient_identifier).to eq("+12025550100")
    end
  end

  describe "#catch_up?" do
    it "comes from the column, defaulting to false" do
      expect(described_class.new).not_to be_catch_up
      expect(described_class.new(catch_up: true)).to be_catch_up
    end
  end
end
