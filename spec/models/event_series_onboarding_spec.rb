require "rails_helper"

RSpec.describe EventSeries, "onboarding config" do
  describe "#haven_onboarding?" do
    it "is off by default" do
      expect(build(:event_series).haven_onboarding?).to be(false)
    end

    it "casts the form checkbox value" do
      expect(build(:event_series, haven_onboarding: "1").haven_onboarding?).to be(true)
      expect(build(:event_series, haven_onboarding: "0").haven_onboarding?).to be(false)
    end

    it "is inherited by the series' events" do
      series = create(:event_series, haven_onboarding: "1")

      expect(create(:event, event_series: series).haven_onboarding?).to be(true)
      expect(create(:event).haven_onboarding?).to be(false)
    end
  end
end
