require "rails_helper"

RSpec.describe Admin::DashboardHelper, type: :helper do
  describe "#event_date_range" do
    it "reads dates in the given zone" do
      expect(helper.event_date_range(Time.utc(2026, 11, 6, 0), Time.utc(2026, 11, 9, 23), zone: "Pacific Time (US & Canada)"))
        .to eq("Nov 5–9, 2026")
    end

    it "accepts plain dates" do
      expect(helper.event_date_range(Date.new(2026, 11, 5), Date.new(2026, 11, 9), zone: "Pacific Time (US & Canada)"))
        .to eq("Nov 5–9, 2026")
    end
  end
end
