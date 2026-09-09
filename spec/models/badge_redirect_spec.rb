require "rails_helper"

RSpec.describe BadgeRedirect, type: :model do
  describe "normalization" do
    it "upcases and trims the Slack ID so lookups match whatever the QR encodes" do
      badge_redirect = create(:badge_redirect, slack_id: "  u01abcdef  ")

      expect(badge_redirect.slack_id).to eq("U01ABCDEF")
      expect(described_class.for_slack_id("u01abcdef")).to eq(badge_redirect)
    end

    it "assumes https when the URL is typed without a scheme" do
      expect(create(:badge_redirect, url: "example.com/me").url).to eq("https://example.com/me")
    end

    it "leaves an explicit scheme alone" do
      expect(create(:badge_redirect, url: "http://example.com").url).to eq("http://example.com")
    end

    it "treats a blank URL as no redirect at all" do
      expect(create(:badge_redirect, url: "   ").url).to be_nil
    end
  end

  describe "validation" do
    it "rejects a scheme that isn't http(s)" do
      badge_redirect = build(:badge_redirect, url: "javascript:alert(1)")

      expect(badge_redirect).not_to be_valid
      expect(badge_redirect.errors[:url]).to be_present
    end

    it "rejects a URL with no host" do
      expect(build(:badge_redirect, url: "https://")).not_to be_valid
    end

    it "rejects a link back to the badge host, which would loop" do
      expect(build(:badge_redirect, url: "https://badge.hackclub.com/t/U01ABCDEF")).not_to be_valid
    end

    it "requires the Slack ID to be unique" do
      create(:badge_redirect, slack_id: "U01ABCDEF")

      expect(build(:badge_redirect, slack_id: "u01abcdef")).not_to be_valid
    end
  end

  describe "#public_url" do
    it "is the printed QR target" do
      expect(build(:badge_redirect, slack_id: "U01ABCDEF").public_url)
        .to eq("https://badge.hackclub.com/t/U01ABCDEF")
    end
  end

  describe "deleting the owner" do
    it "keeps the redirect working" do
      user = create(:user)
      badge_redirect = create(:badge_redirect, user: user)

      user.destroy!

      expect(badge_redirect.reload.user).to be_nil
      expect(badge_redirect.url).to be_present
    end
  end
end
