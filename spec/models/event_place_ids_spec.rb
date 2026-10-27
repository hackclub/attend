require "rails_helper"

RSpec.describe Event, "place ids" do
  include ActiveJob::TestHelper

  it "queues a lookup when a venue is added to a located event" do
    event = create(:event)
    expect { event.update!(venue_name: "Mock Hall") }.to have_enqueued_job(ResolveVenuePlaceIdsJob).with(event.id)
  end

  it "does not queue a lookup for a venue without coordinates" do
    allow(GeocoderService).to receive(:geocode).and_return(nil)
    event = create(:event, location_latitude: nil, location_longitude: nil)
    expect { event.update!(venue_name: "Mock Hall") }.not_to have_enqueued_job(ResolveVenuePlaceIdsJob)
  end

  it "clears stale ids when the venue changes and queues a fresh lookup" do
    event = create(:event, venue_name: "Mock Hall", apple_place_id: "IOLD", google_place_id: "ChIJold")
    clear_enqueued_jobs

    expect { event.update!(venue_name: "Mock Arena") }.to have_enqueued_job(ResolveVenuePlaceIdsJob)
    expect(event.reload).to have_attributes(apple_place_id: nil, google_place_id: nil)
  end

  it "keeps an id picked in the same save as the venue change" do
    event = create(:event, venue_name: "Mock Hall", apple_place_id: "IOLD", google_place_id: "ChIJold")

    event.update!(venue_name: "Mock Arena", location_address: "1 Mock Way", google_place_id: "ChIJnew")

    expect(event.reload).to have_attributes(apple_place_id: nil, google_place_id: "ChIJnew")
  end

  it "does not queue a lookup when both ids are already known" do
    event = create(:event, venue_name: "Mock Hall", apple_place_id: "IOLD", google_place_id: "ChIJold")
    clear_enqueued_jobs
    expect { event.update!(name: "Renamed") }.not_to have_enqueued_job(ResolveVenuePlaceIdsJob)
  end
end
