require "rails_helper"

RSpec.describe Event, "geocoding on save" do
  let(:geocoded) { { latitude: 51.5.to_d, longitude: -0.1.to_d, formatted_address: "Mock Hall" } }

  before { allow(GeocoderService).to receive(:geocode).and_return(geocoded) }

  it "geocodes a new event that has a city but no coordinates" do
    event = create(:event, location_latitude: nil, location_longitude: nil)

    expect(GeocoderService).to have_received(:geocode).with("San Francisco, USA")
    expect(event.reload.location_latitude).to eq(51.5)
  end

  it "re-geocodes a pinned event when its address changes" do
    event = create(:event)
    allow(GeocoderService).to receive(:geocode).and_return(geocoded.merge(latitude: 40.0.to_d, longitude: -74.0.to_d))

    event.update!(location_address: "1 Mock Way")

    expect(event.reload.location_latitude).to eq(40.0)
  end

  it "keeps coordinates supplied with the address change" do
    event = create(:event)

    event.update!(location_address: "1 Mock Way", location_latitude: 48.0, location_longitude: 2.0)

    expect(GeocoderService).not_to have_received(:geocode)
    expect(event.reload.location_latitude).to eq(48.0)
  end

  it "leaves a pinned event alone when only the venue name changes" do
    event = create(:event)

    event.update!(venue_name: "Mock Hall")

    expect(GeocoderService).not_to have_received(:geocode)
  end

  it "does not geocode on unrelated changes" do
    allow(GeocoderService).to receive(:geocode).and_return(nil)
    event = create(:event, location_latitude: nil, location_longitude: nil)

    event.update!(name: "Renamed")

    expect(GeocoderService).to have_received(:geocode).once
  end
end
