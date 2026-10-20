require "rails_helper"

RSpec.describe "Onboarding branding", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:brand) do
    {
      "background" => "#fff6d6", "ink" => "#4a2a12", "accent" => "#ed5615",
      "body_font" => "jua", "heading_font" => "darumadrop-one", "nav_style" => "progress",
      "mascot_image" => "brands/haven/hedgehog.webp", "footer_image" => "brands/haven/bottom-bushes.webp"
    }
  end
  let(:series) do
    create(:event_series, name: "Sunbeam", brand: brand,
      registration_note: "Bring a laptop to build on.",
      address_note: "We post stickers to this address.",
      tshirt_note: "Unisex, US sizing.")
  end
  let(:event) { create(:event, name: "Sunbeam Springfield", event_series: series, venue_name: "Town Library", location_city: "Springfield") }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user) }

  before do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 0, onboarding_intro_seen_at: Time.current)
    sign_in user
  end

  it "renders the brand's tokens, fonts, artwork and copy" do
    get onboarding_step_path(step: "profile", event_id: event.id)

    expect(response).to have_http_status(:ok)
    html = Nokogiri::HTML(response.body).at("html")
    expect(html["data-theme"]).to eq("light")
    expect(html["data-branded"]).to eq("")
    expect(html["data-brand-heading-font"]).to eq("")
    expect(html["data-brand-single-weight"]).to eq("")
    expect(response.body).to include('html[data-branded][data-theme="light"] { --bg-app: #fff6d6;')
    expect(response.body).to include("--text-strong: #4a2a12;")
    expect(response.body).to include("--brand-font-heading: \"Darumadrop One\", \"Jua Extras\", \"Jua\"")
    expect(response.body).to include("brand-bottom-strip")
    expect(response.body).to include("hedgehog")
    expect(response.body).to include("Step 1 of")
    expect(response.body).to include("Town Library, Springfield")
    expect(response.body).to include("We post stickers to this address.")
    expect(response.body).to include("Unisex, US sizing.")
  end

  it "keeps a user's own theme, applying the colours only on light" do
    cookies[:attend_theme] = "dracula"

    get onboarding_step_path(step: "profile", event_id: event.id)

    html = Nokogiri::HTML(response.body).at("html")
    expect(html["data-theme"]).to eq("dracula")
    expect(html["data-branded"]).to eq("")
    expect(response.body).to include('html[data-branded][data-theme="light"]')
  end

  it "adds the registration note to the review step" do
    participant.participant_events.find_by!(event: event).update!(onboarding_step: 99)

    get onboarding_step_path(step: "review", event_id: event.id)

    expect(response.body).to include("Bring a laptop to build on.")
  end

  context "when the series has no branding" do
    let(:series) { create(:event_series, name: "Plain") }

    it "keeps the stock look and copy" do
      get onboarding_step_path(step: "profile", event_id: event.id)

      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body).at("html")
      expect(html["data-branded"]).to be_nil
      expect(response.body).not_to include("brand-bottom-strip")
      expect(response.body).not_to include("We post stickers")
      expect(response.body).to include("Registering for")
    end
  end
end

RSpec.describe "Onboarding invitation entry with branding", type: :request do
  let(:series) { create(:event_series, name: "Sunbeam", brand: { "background" => "#fff6d6", "ink" => "#4a2a12", "accent" => "#ed5615" }) }
  let(:event) { create(:event, name: "Sunbeam Springfield", event_series: series) }
  let(:invitation) { create(:invitation, event: event, email: "invited@example.com", sent_at: Time.current) }

  it "brands the signed-out invitation page" do
    get onboarding_path(invite: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at("html")["data-branded"]).to eq("")
    expect(response.body).to include("You&#39;re invited to")
    expect(response.body).to include("Register for Sunbeam Springfield")
  end

  it "leaves invitations for unbranded events alone" do
    event.update!(event_series: nil)

    get onboarding_path(invite: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at("html")["data-branded"]).to be_nil
  end
end
