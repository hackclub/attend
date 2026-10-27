require "rails_helper"

RSpec.describe GeocoderService do
  let(:credentials) { double("credentials") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GEOCODER_API_KEY").and_return(nil)
    allow(Rails.application).to receive(:credentials).and_return(credentials)
    allow(credentials).to receive(:geocoder_api_key).and_return(nil)
    allow(credentials).to receive(:dig).with(:geocoder, :api_key).and_return(nil)
  end

  def stub_geocode(key)
    stub_request(:get, "https://geocoder.hackclub.com/v1/geocode")
      .with(query: { address: "Mock Hall, Mock City", key: key })
      .to_return(status: 200, body: { lat: 51.5, lng: -0.1, formatted_address: "Mock Hall, Mock City" }.to_json)
  end

  it "reads the key from the top-level credential production uses" do
    allow(credentials).to receive(:geocoder_api_key).and_return("top-level-key")
    stub_geocode("top-level-key")

    expect(described_class.geocode("Mock Hall, Mock City")).to include(latitude: 51.5, longitude: -0.1)
  end

  it "prefers the env var when set" do
    allow(ENV).to receive(:[]).with("GEOCODER_API_KEY").and_return("env-key")
    allow(credentials).to receive(:geocoder_api_key).and_return("top-level-key")
    stub_geocode("env-key")

    expect(described_class.geocode("Mock Hall, Mock City")).to include(latitude: 51.5)
  end

  it "still accepts the nested credential" do
    allow(credentials).to receive(:dig).with(:geocoder, :api_key).and_return("nested-key")
    stub_geocode("nested-key")

    expect(described_class.geocode("Mock Hall, Mock City")).to include(latitude: 51.5)
  end

  it "warns and returns nil when no key is configured" do
    allow(Rails.logger).to receive(:warn)

    expect(described_class.geocode("Mock Hall, Mock City")).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/no API key configured/)
    expect(a_request(:get, /geocoder\.hackclub\.com/)).not_to have_been_made
  end
end
