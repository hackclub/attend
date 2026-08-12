require "rails_helper"
require "omniauth/strategies/hack_club"

RSpec.describe OmniAuth::Strategies::HackClub do
  subject(:strategy) { described_class.new(nil) }

  # `/api/v1/me` — the shape HCA actually returns: no name fields at all.
  let(:identity_response) do
    {
      "identity" => {
        "id" => "ident!ABC123",
        "primary_email" => "sofiacegan@gmail.com",
        "slack_id" => "U07BLJ1MBEE",
        "verification_status" => "verified",
        "ysws_eligible" => true
      },
      "scopes" => [ "openid", "profile", "email" ]
    }
  end

  # `/oauth/userinfo` — where the standard OIDC name claims live.
  let(:userinfo_response) do
    {
      "sub" => "ident!ABC123",
      "email" => "sofiacegan@gmail.com",
      "name" => "Sofia Cegan",
      "given_name" => "Sofia",
      "family_name" => "Cegan",
      "birthdate" => "2008-04-02"
    }
  end

  def stub_endpoints(userinfo:)
    access_token = double("access_token")
    allow(access_token).to receive(:get).with("/api/v1/me")
      .and_return(double(parsed: identity_response))
    if userinfo.is_a?(StandardError)
      allow(access_token).to receive(:get).with("/oauth/userinfo").and_raise(userinfo)
    else
      allow(access_token).to receive(:get).with("/oauth/userinfo")
        .and_return(double(parsed: userinfo))
    end
    allow(strategy).to receive(:access_token).and_return(access_token)
  end

  describe "#info" do
    it "takes the name from the userinfo claims" do
      stub_endpoints(userinfo: userinfo_response)

      expect(strategy.info).to include(
        email: "sofiacegan@gmail.com",
        first_name: "Sofia",
        last_name: "Cegan",
        name: "Sofia Cegan"
      )
    end

    it "falls back to the email local part when HCA has no name" do
      stub_endpoints(userinfo: { "sub" => "ident!ABC123", "email" => "sofiacegan@gmail.com" })

      expect(strategy.info[:name]).to eq("sofiacegan")
    end

    it "still signs the user in when userinfo is unavailable" do
      stub_endpoints(userinfo: OAuth2::Error.new(double(parsed: {}, body: "", status: 500)))

      expect(strategy.uid).to eq("ident!ABC123")
      expect(strategy.info[:email]).to eq("sofiacegan@gmail.com")
    end
  end

  describe "#uid" do
    it "keeps using the HCA identity id" do
      stub_endpoints(userinfo: userinfo_response)

      expect(strategy.uid).to eq("ident!ABC123")
    end
  end

  describe "#extra" do
    it "merges both payloads into raw_info" do
      stub_endpoints(userinfo: userinfo_response)

      raw_info = strategy.extra[:raw_info]
      expect(raw_info["given_name"]).to eq("Sofia")
      expect(raw_info.dig("identity", "slack_id")).to eq("U07BLJ1MBEE")
    end
  end
end
