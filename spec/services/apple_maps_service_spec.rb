require "rails_helper"

RSpec.describe AppleMapsService do
  let(:ec_key) { OpenSSL::PKey::EC.generate("prime256v1").to_pem }

  before do
    allow(described_class).to receive(:key_id).and_return("KEYID12345")
    allow(described_class).to receive(:private_key).and_return(ec_key)
    allow(described_class).to receive(:team_id).and_return("TEAMID1234")
    Rails.cache.delete(described_class::TOKEN_CACHE_KEY)
    stub_request(:get, "https://maps-api.apple.com/v1/token")
      .to_return(status: 200, body: { accessToken: "access-123", expiresInSeconds: 1800 }.to_json)
  end

  def stub_search(results)
    stub_request(:get, "https://maps-api.apple.com/v1/search")
      .with(query: hash_including("q" => "Mock Hall", "resultTypeFilter" => "Poi"), headers: { "Authorization" => "Bearer access-123" })
      .to_return(status: 200, body: { results: results }.to_json)
  end

  it "signs an ES256 JWT apple will accept the shape of" do
    header, payload, signature = described_class.auth_token.split(".")
    expect(JSON.parse(Base64.urlsafe_decode64(header))).to include("alg" => "ES256", "kid" => "KEYID12345")
    expect(JSON.parse(Base64.urlsafe_decode64(payload))).to include("iss" => "TEAMID1234")
    expect(Base64.urlsafe_decode64(signature).bytesize).to eq(64)
  end

  it "returns the nearest point of interest with its id" do
    stub_search([
      { "id" => "IFARAWAY", "name" => "Mock Hall", "coordinate" => { "latitude" => 51.60, "longitude" => -0.10 } },
      { "id" => "INEARBY", "name" => "Mock Hall", "coordinate" => { "latitude" => 51.5012, "longitude" => -0.1011 } }
    ])

    place = described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)
    expect(place).to include(id: "INEARBY", name: "Mock Hall")
  end

  it "ignores hits without an id or too far from the venue" do
    stub_search([
      { "name" => "Mock Street 1", "coordinate" => { "latitude" => 51.5, "longitude" => -0.1 } },
      { "id" => "IFARAWAY", "name" => "Mock Hall", "coordinate" => { "latitude" => 52.0, "longitude" => -0.1 } }
    ])

    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to be_nil
  end

  it "reuses the access token across lookups" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    stub_search([])
    2.times { described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1) }
    expect(a_request(:get, "https://maps-api.apple.com/v1/token")).to have_been_made.once
  end

  it "returns nil when the API is unreachable" do
    stub_request(:get, "https://maps-api.apple.com/v1/search").with(query: hash_including({})).to_timeout
    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to be_nil
  end

  it "does nothing without credentials" do
    allow(described_class).to receive(:key_id).and_return(nil)
    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to be_nil
    expect(a_request(:get, "https://maps-api.apple.com/v1/token")).not_to have_been_made
  end
end
