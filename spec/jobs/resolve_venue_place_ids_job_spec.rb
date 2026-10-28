require "rails_helper"

RSpec.describe ResolveVenuePlaceIdsJob do
  let(:event) { create(:event, venue_name: "Mock Hall", location_latitude: 51.5, location_longitude: -0.1) }

  it "fills in whichever ids are missing" do
    event.update_columns(google_place_id: "ChIJpicked")
    allow(AppleMapsService).to receive(:find_place).and_return({ id: "IAPPLE" })
    allow(GooglePlacesService).to receive(:find_place)

    described_class.perform_now(event.id)

    expect(event.reload).to have_attributes(apple_place_id: "IAPPLE", google_place_id: "ChIJpicked")
    expect(GooglePlacesService).not_to have_received(:find_place)
  end

  it "leaves the event alone when a lookup finds nothing" do
    allow(AppleMapsService).to receive(:find_place).and_return(nil)
    allow(GooglePlacesService).to receive(:find_place).and_return(nil)

    expect { described_class.perform_now(event.id) }.not_to change { event.reload.updated_at }
    expect(event.apple_place_id).to be_nil
  end

  it "skips events without a venue name or coordinates" do
    bare = create(:event, venue_name: nil)
    allow(AppleMapsService).to receive(:find_place)
    described_class.perform_now(bare.id)
    expect(AppleMapsService).not_to have_received(:find_place)
  end
end
