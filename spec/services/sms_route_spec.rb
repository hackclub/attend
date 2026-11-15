require "rails_helper"

RSpec.describe SmsRoute do
  describe ".sender_for" do
    it "uses the long code for +1 and countries it delivers to" do
      expect(described_class.sender_for("+14155551234", long_code: "+15075550100")).to eq("+15075550100")
      expect(described_class.sender_for("+919876543210", long_code: "+15075550100")).to eq("+15075550100")
    end

    it "uses the Hack Club sender for the UK, including numbers that parse as Guernsey" do
      expect(described_class.sender_for("+447911123456", long_code: "+15075550100")).to eq("Hack Club")
    end

    it "has no sender for the countries we don't text" do
      %w[+998901234567 +639171234567 +923001234567 +5215512345678].each do |phone|
        expect(described_class.sender_for(phone, long_code: "+15075550100")).to be_nil
      end
    end
  end

  describe ".no_sms_country_for" do
    it "names the country of a number we can't text" do
      expect(described_class.no_sms_country_for("+998901234567")).to eq("UZ")
    end

    it "is nil for numbers we can text" do
      expect(described_class.no_sms_country_for("+14155551234")).to be_nil
      expect(described_class.no_sms_country_for("")).to be_nil
    end
  end

  describe ".no_sms_country_named" do
    it "recognises the ways events write those countries" do
      expect(described_class.no_sms_country_named("Uzbekistan")).to eq("UZ")
      expect(described_class.no_sms_country_named(" uz ")).to eq("UZ")
      expect(described_class.no_sms_country_named("UAE")).to eq("AE")
      expect(described_class.no_sms_country_named("The Philippines")).to eq("PH")
    end

    it "ignores countries we can text and blanks" do
      expect(described_class.no_sms_country_named("United Kingdom")).to be_nil
      expect(described_class.no_sms_country_named("USA")).to be_nil
      expect(described_class.no_sms_country_named(nil)).to be_nil
    end
  end
end
