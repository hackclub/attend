require "rails_helper"

RSpec.describe EventSeries, "branding and account linking" do
  let(:brand) { { "background" => "#fff6d6", "ink" => "#4a2a12", "accent" => "#ed5615" } }

  describe "brand" do
    it "is inherited by the series' events" do
      series = create(:event_series, brand: brand)

      expect(create(:event, event_series: series).brand_theme).to be_active
      expect(create(:event).brand_theme).to be_nil
    end

    it "won't save colours that fail contrast" do
      series = build(:event_series, brand: brand.merge("ink" => "#eeeeee"))

      expect(series).not_to be_valid
      expect(series.errors[:brand].join).to include("below the 4.5:1 minimum")
    end

    it "files field errors under the field" do
      series = build(:event_series, brand: brand.merge("heading_font" => "papyrus"))

      expect(series).not_to be_valid
      expect(series.errors[:brand_heading_font]).to be_present
    end
  end

  describe "account linking" do
    let(:series) { create(:event_series, github_linking: "required", github_help_url: "https://example.com/github-howto") }

    it "follows the series unless the event sets its own" do
      event = create(:event, event_series: series)
      expect(event.account_linking_mode("github")).to eq("required")
      expect(event.account_help_url("github")).to eq("https://example.com/github-howto")

      event.update!(github_linking: "off", github_help_url: "https://example.com/ours")
      expect(event.account_linking_mode("github")).to eq("off")
      expect(event.account_help_url("github")).to eq("https://example.com/ours")

      event.update!(github_linking: "")
      expect(event.account_linking_mode("github")).to eq("required")
    end

    it "works for events outside any series" do
      event = create(:event, itch_linking: "optional")

      expect(event.linked_account_providers).to eq(%w[itch])
      expect(event.required_account_providers).to be_empty
    end

    it "rejects unknown modes and non-https help links" do
      event = build(:event, github_linking: "always", itch_help_url: "http://example.com")

      expect(event).not_to be_valid
      expect(event.errors.attribute_names).to include(:github_linking, :itch_help_url)
    end
  end
end
