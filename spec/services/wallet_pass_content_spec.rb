require "rails_helper"

RSpec.describe WalletPassContent do
  let(:participant_event) { create(:participant_event) }
  let(:event) { participant_event.event }
  let(:pass) do
    Passkit::Pass.create!(
      klass: "Passkit::EventTicket",
      generator: participant_event,
      serial_number: SecureRandom.uuid,
      authentication_token: SecureRandom.hex(16)
    )
  end

  # Smallest valid PNG (1x1 transparent pixel)
  let(:png) do
    Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
  end

  describe ".digest" do
    it "is stable across builds of an unchanged pass" do
      expect(described_class.digest(pass)).to eq(described_class.digest(Passkit::Pass.find(pass.id)))
    end

    it "changes with a field shown on the pass" do
      before = described_class.digest(pass)
      event.update!(venue_name: "Somewhere New")

      expect(described_class.digest(Passkit::Pass.find(pass.id))).not_to eq(before)
    end

    it "changes when the event's banner is replaced" do
      before = described_class.digest(pass)
      event.banner.attach(io: StringIO.new(png), filename: "banner.png", content_type: "image/png")

      expect(described_class.digest(Passkit::Pass.find(pass.id))).not_to eq(before)
    end

    it "ignores fields the pass doesn't show" do
      before = described_class.digest(pass)
      participant_event.participant.update!(pronouns: "they/them")

      expect(described_class.digest(Passkit::Pass.find(pass.id))).to eq(before)
    end
  end

  describe ".refresh!" do
    it "reports a first fingerprint as changed by default" do
      expect(described_class.refresh!(pass)).to be(true)
    end

    it "keeps the existing last-modified for a first fingerprint marked unknown: :unchanged" do
      legacy = pass.last_update

      expect(described_class.refresh!(pass, unknown: :unchanged)).to be(false)
      expect(pass.reload.content_updated_at.to_i).to eq(legacy.to_i)
    end

    it "reports no change once fingerprinted" do
      described_class.refresh!(pass)

      expect(described_class.refresh!(pass.reload)).to be(false)
    end
  end
end
