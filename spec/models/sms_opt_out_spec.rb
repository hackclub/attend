require "rails_helper"

RSpec.describe SmsOptOut do
  describe ".keyword_action" do
    it "reads Twilio's stop and start words, whatever the case and spacing" do
      expect(described_class.keyword_action(" stop ")).to eq(:stop)
      expect(described_class.keyword_action("Stop all")).to eq(:stop)
      expect(described_class.keyword_action("Unsubscribe")).to eq(:stop)
      expect(described_class.keyword_action("start")).to eq(:start)
    end

    it "ignores ordinary messages, even ones containing the words" do
      expect(described_class.keyword_action("please stop texting me at 9pm")).to be_nil
      expect(described_class.keyword_action("What time does it start?")).to be_nil
    end

    it "trusts Twilio's OptOutType when present" do
      expect(described_class.keyword_action("arrêt", opt_out_type: "STOP")).to eq(:stop)
    end
  end

  describe "link tokens" do
    it "round-trips a number" do
      token = described_class.token_for("+447911123456")

      expect(token).to start_with("447911123456-")
      expect(described_class.phone_for_token(token)).to eq("+447911123456")
    end

    it "rejects a token whose number was changed" do
      sig = described_class.token_for("+447911123456").split("-").last

      expect(described_class.phone_for_token("447911123457-#{sig}")).to be_nil
      expect(described_class.phone_for_token("447911123456")).to be_nil
    end
  end

  it "opts a number out and back in" do
    described_class.opt_out!("+447911123456", source: :keyword)
    expect(described_class.opted_out?("+447911123456")).to be(true)

    described_class.opt_in!("+447911123456")
    expect(described_class.opted_out?("+447911123456")).to be(false)
  end
end
