require "rails_helper"

RSpec.describe PhoneNormalizer do
  describe ".normalize" do
    it "returns E.164 for a number that already carries its country code" do
      expect(described_class.normalize("+44 7911 123456")).to eq("+447911123456")
      expect(described_class.normalize("+1 (415) 555-0132")).to eq("+14155550132")
    end

    it "reads the international access prefix as a country code" do
      expect(described_class.normalize("00447911123456")).to eq("+447911123456")
    end

    it "strips the channel prefixes Twilio puts on inbound addresses" do
      expect(described_class.normalize("whatsapp:+14155550132")).to eq("+14155550132")
      expect(described_class.normalize("tel:+14155550132")).to eq("+14155550132")
    end

    it "interprets a bare national number against the default country" do
      expect(described_class.normalize("4155550132")).to eq("+14155550132")
    end

    # The shapes of number that prompted this work. Every one is "possible"
    # by Phonelib's length check and undialable in reality.
    describe "numbers that are possible but not valid" do
      {
        "a national-format number with no country code" => "0555550100",
        "a country code glued to a national trunk prefix" => "+1 0555550100",
        "too few digits to be a real subscriber number" => "15555555",
        "an all-zero placeholder" => "0000000000"
      }.each do |description, input|
        it "rejects #{description} (#{input})" do
          expect(Phonelib.parse(input).possible?).to be(true), "expected #{input} to be the possible-but-invalid case this guards"
          expect(described_class.normalize(input)).to be_nil
        end
      end
    end

    it "rejects a national number from a country other than the default" do
      # A UK mobile typed without +44 must not silently become a US number.
      expect(described_class.normalize("07911123456")).to be_nil
    end

    it "never returns the raw input when it cannot parse" do
      expect(described_class.normalize("not a phone")).to be_nil
      expect(described_class.normalize("123")).to be_nil
      expect(described_class.normalize("+")).to be_nil
    end

    it "returns nil for blank input" do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("")).to be_nil
      expect(described_class.normalize("   ")).to be_nil
    end

    context "with default_country: nil" do
      it "requires an explicit country code" do
        expect(described_class.normalize("4155550132", default_country: nil)).to be_nil
        expect(described_class.normalize("+14155550132", default_country: nil)).to eq("+14155550132")
      end
    end

    it "lets an explicit country code win over the default country" do
      expect(described_class.normalize("+447911123456", default_country: "US")).to eq("+447911123456")
    end

    it "is idempotent" do
      once = described_class.normalize("+1 (415) 555-0132")
      expect(described_class.normalize(once)).to eq(once)
    end
  end

  describe ".valid?" do
    it "mirrors normalize" do
      expect(described_class.valid?("+14155550132")).to be(true)
      expect(described_class.valid?("15555555")).to be(false)
      expect(described_class.valid?(nil)).to be(false)
    end
  end

  describe ".country" do
    it "resolves the country of a valid number" do
      expect(described_class.country("+447911123456")).to eq("GG").or eq("GB")
      expect(described_class.country("15555555")).to be_nil
    end
  end
end
