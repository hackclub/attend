require "rails_helper"

RSpec.describe GooglePlacesService do
  before { allow(described_class).to receive(:api_key).and_return("test-key") }

  def stub_search(places)
    stub_request(:post, "https://places.googleapis.com/v1/places:searchText")
      .with(headers: { "X-Goog-Api-Key" => "test-key" }, body: hash_including("textQuery" => "Mock Hall"))
      .to_return(status: 200, body: { places: places }.to_json)
  end

  it "returns the nearest place with its id" do
    stub_search([
      { "id" => "ChIJfar", "displayName" => { "text" => "Mock Hall" }, "location" => { "latitude" => 52.0, "longitude" => -0.1 } },
      { "id" => "ChIJnear", "displayName" => { "text" => "Mock Hall" }, "location" => { "latitude" => 51.5005, "longitude" => -0.1 } }
    ])

    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to include(id: "ChIJnear", name: "Mock Hall")
  end

  it "returns nil when nothing is close enough" do
    stub_search([ { "id" => "ChIJfar", "location" => { "latitude" => 52.0, "longitude" => -0.1 } } ])
    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to be_nil
  end

  it "returns nil on a failed request" do
    stub_request(:post, "https://places.googleapis.com/v1/places:searchText").to_return(status: 403, body: "{}")
    expect(described_class.find_place(name: "Mock Hall", latitude: 51.5, longitude: -0.1)).to be_nil
  end
end
