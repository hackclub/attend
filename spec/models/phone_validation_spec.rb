require "rails_helper"

# Stand-ins for the shapes of number that were reaching production. Every one
# passes the previous `phone: { possible: true }` length-only check.
INVALID_PHONE_NUMBERS = [
  "0555550100",     # national format, country code missing entirely
  "+1 0555550100",  # country code glued onto a national trunk prefix
  "15555555",       # too short to be a subscriber number
  "07911123456",    # UK national format, no +44
  "0000000000",
  "555",
  "not a phone"
].freeze

VALID_PHONE_NUMBERS = {
  "+14155550132" => "+14155550132",
  "+1 (415) 555-0132" => "+14155550132",
  "4155550132" => "+14155550132",
  "+44 7911 123456" => "+447911123456",
  "00447911123456" => "+447911123456"
}.freeze

RSpec.describe "phone number validation" do
  shared_examples "a strictly validated phone attribute" do |attribute|
    INVALID_PHONE_NUMBERS.each do |bad|
      it "rejects #{bad.inspect}" do
        record = build_record(attribute => bad)
        expect(record).not_to be_valid, "expected #{bad.inspect} to be rejected on #{described_class}##{attribute}"
        expect(record.errors[attribute].join).to match(/valid phone number/i)
      end
    end

    VALID_PHONE_NUMBERS.each do |input, expected|
      it "accepts #{input.inspect} and stores it as #{expected}" do
        record = build_record(attribute => input)
        expect(record).to be_valid, record.errors.full_messages.join(", ")
        expect(record.public_send(attribute)).to eq(expected)
      end
    end
  end

  describe Participant do
    def build_record(attrs) = build(:participant, **attrs)
    it_behaves_like "a strictly validated phone attribute", :phone

    it "allows a blank phone" do
      expect(build(:participant, phone: nil)).to be_valid
      expect(build(:participant, phone: "")).to be_valid
    end
  end

  describe Guardian do
    def build_record(attrs) = build(:guardian, **attrs)
    it_behaves_like "a strictly validated phone attribute", :phone

    it "allows a blank phone" do
      expect(build(:guardian, phone: nil)).to be_valid
    end
  end

  describe EmergencyContact do
    let(:participant_event) { create(:participant_event) }
    def build_record(attrs)
      EmergencyContact.new(
        participant_event: participant_event,
        name: "Sam Rivers",
        relationship: "Aunt",
        priority: 1,
        **attrs
      )
    end
    it_behaves_like "a strictly validated phone attribute", :phone

    it "still requires a phone to be present" do
      record = build_record(phone: nil)
      expect(record).not_to be_valid
      expect(record.errors[:phone]).to include("can't be blank")
    end
  end

  describe "normalization is idempotent across saves" do
    it "leaves an already-normalized number untouched" do
      participant = create(:participant, phone: "+1 (415) 555-0132")
      expect(participant.phone).to eq("+14155550132")
      participant.update!(preferred_name: "Robin")
      expect(participant.reload.phone).to eq("+14155550132")
    end
  end
end
