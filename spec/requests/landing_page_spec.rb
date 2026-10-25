require "rails_helper"

RSpec.describe "Landing page", type: :request do
  before { Rails.cache.delete(LandingStats::CACHE_KEY) }

  it "renders the live sentence, the country roll, and the map pins for signed-out visitors" do
    event = create(:event, name: "Mock Harbour", starts_at: 2.weeks.ago, ends_at: 13.days.ago,
                   location_city: "Rotterdam", location_country: "Netherlands")
    participant = create(:participant, country_of_residence: "Netherlands")
    create(:participant_event, participant: participant, event: event, status: :complete)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Attend has enabled")
    expect(response.body).to include("Continue with Hack Club")
    expect(response.body).to include("Parent or guardian")
    expect(response.body).to include("Report an incident")
    expect(response.body).to include("landing-country-name\">Netherlands<")
    expect(response.body).to include("data-landing-map-pins-value")
    expect(response.body).to include("Rotterdam, Netherlands")
  end

  it "survives an empty database" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Attend has enabled")
  end

  it "escapes event names in the pins payload" do
    event = create(:event, name: "<script>alert(1)</script>", starts_at: 2.weeks.ago, ends_at: 13.days.ago)
    create(:participant_event, event: event, status: :complete)

    get root_path

    # Rails' JSON encoder writes angle brackets as <, and the attribute
    # value is HTML-escaped on top, so the name never forms a tag.
    expect(response.body).not_to include("<script>alert(1)</script>")
    expect(response.body).to include("\\u003cscript\\u003ealert(1)\\u003c/script\\u003e")
  end
end
