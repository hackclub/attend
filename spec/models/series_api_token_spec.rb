require "rails_helper"

RSpec.describe SeriesApiToken, type: :model do
  let(:series) { create(:event_series) }
  let(:user) { create(:user, email: "organizer@hackclub.com") }

  describe ".generate_for" do
    it "returns the raw secret once and stores only its digest" do
      token = described_class.generate_for(series, user: user, name: "ops")

      expect(token.token).to start_with("attn_")
      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(token.token))
      expect(described_class.find(token.id).token).to be_nil
    end

    it "prefixes the name with the creator's email local part" do
      token = described_class.generate_for(series, user: user, name: "ops")

      expect(token.name).to eq("organizer@ops")
    end

    it "keeps the raw name when there is no creator" do
      token = described_class.generate_for(series, user: nil, name: "ops")

      expect(token.name).to eq("ops")
    end
  end

  describe ".find_by_token" do
    it "finds an active token by its secret" do
      token = described_class.generate_for(series, user: user, name: "ops")

      expect(described_class.find_by_token(token.token)).to eq(token)
    end

    it "ignores a revoked token" do
      token = described_class.generate_for(series, user: user, name: "ops")
      token.revoke!

      expect(described_class.find_by_token(token.token)).to be_nil
    end

    it "returns nil for a blank or unknown secret" do
      expect(described_class.find_by_token(nil)).to be_nil
      expect(described_class.find_by_token("")).to be_nil
      expect(described_class.find_by_token("attn_nope")).to be_nil
    end
  end

  describe "#rotate!" do
    it "swaps the secret, keeps the name, and clears the usage stamp" do
      token = described_class.generate_for(series, user: user, name: "ops")
      original = token.token
      token.touch_last_used!

      new_secret = token.rotate!

      expect(new_secret).not_to eq(original)
      expect(described_class.find_by_token(original)).to be_nil
      expect(described_class.find_by_token(new_secret)).to eq(token)
      expect(token.reload.name).to eq("organizer@ops")
      expect(token.last_used_at).to be_nil
    end
  end

  it "outlives its creator's user row" do
    token = described_class.generate_for(series, user: user, name: "ops")
    user.destroy!

    expect(token.reload.user).to be_nil
    expect(described_class.find_by_token(token.token)).to eq(token)
  end

  it "goes away with its series" do
    token = described_class.generate_for(series, user: user, name: "ops")

    series.destroy!

    expect(described_class).not_to exist(token.id)
  end
end
