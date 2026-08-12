require "rails_helper"

RSpec.describe "Public profiles", type: :request do
  # 1x1 transparent PNG
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  ).freeze

  let(:participant) do
    create(:participant, legal_first_name: "Grace", legal_last_name: "Hopper",
                         pronouns: "she/her",
                         public_profile_enabled: true, public_profile_bio: "I love hackathons!")
  end

  def past_event(attrs = {})
    create(:event, { starts_at: 3.months.ago, ends_at: 3.months.ago + 2.days,
                     registration_close_at: 4.months.ago }.merge(attrs))
  end

  describe "GET /p/:slug" do
    it "renders the profile when enabled" do
      get public_profile_path(slug: participant.public_profile_slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Grace Hopper")
      expect(response.body).to include("she/her")
      expect(response.body).to include("I love hackathons!")
      expect(response.body).to include('<meta name="robots" content="noindex, nofollow">')
    end

    it "resolves uppercase slugs from pasted links" do
      get "/p/#{participant.public_profile_slug.upcase}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Grace Hopper")
    end

    it "404s for unknown slugs" do
      get "/p/nobody-here"

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Profile not found")
    end

    it "404s when the profile is not enabled" do
      participant.update!(public_profile_enabled: false)

      get "/p/#{participant.public_profile_slug}"

      expect(response).to have_http_status(:not_found)
    end

    it "shows past checked-in events only" do
      create(:participant_event, :checked_in, participant: participant,
                                              event: past_event(name: "Past Hackathon"), status: :complete)
      create(:participant_event, :checked_in, participant: participant,
                                              event: create(:event, name: "Future Hackathon"), status: :complete)
      create(:participant_event, :checked_in, participant: participant,
                                              event: past_event(name: "Hidden Hackathon"), status: :complete,
                                              hidden_from_public_profile: true)
      create(:participant_event, :checked_in, participant: participant,
                                              event: past_event(name: "Withdrawn Hackathon"), status: :withdrawn)
      create(:participant_event, participant: participant,
                                 event: past_event(name: "No-show Hackathon"), status: :complete)

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body).to include("Past Hackathon")
      expect(response.body).not_to include("Future Hackathon")
      expect(response.body).not_to include("Hidden Hackathon")
      expect(response.body).not_to include("Withdrawn Hackathon")
      expect(response.body).not_to include("No-show Hackathon")
    end

    it "shows past staffed events with a staff badge" do
      user = create(:user)
      participant.update!(user: user)
      create(:event_role_assignment, user: user, event: past_event(name: "Ops Weekend"))
      create(:event_role_assignment, user: user, event: create(:event, name: "Upcoming Staff Retreat"))
      create(:event_role_assignment, user: user, event: past_event(name: "Undisclosed Summit"),
                                     hidden_from_public_profile: true)

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body).to include("Ops Weekend")
      expect(response.body).to include("Staff")
      expect(response.body).to include("1 Hack Club event staffed")
      expect(response.body).not_to include("Upcoming Staff Retreat")
      expect(response.body).not_to include("Undisclosed Summit")
    end

    it "shows an event attended and staffed once, with both counted" do
      user = create(:user)
      participant.update!(user: user)
      event = past_event(name: "Dual Role Hackathon")
      create(:participant_event, :checked_in, participant: participant, event: event, status: :complete)
      create(:event_role_assignment, user: user, event: event)
      create(:event_role_assignment, user: user, event: event, role: "event_admin")

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body.scan("Dual Role Hackathon").size).to eq(1)
      expect(response.body).to include("1 Hack Club event attended")
      expect(response.body).to include("1 staffed")
    end

    it "does not leak staff events from an unlinked user" do
      other_user = create(:user)
      create(:event_role_assignment, user: other_user, event: past_event(name: "Someone Else's Event"))

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body).not_to include("Someone Else&#39;s Event")
    end

    it "only shows the headshot when the participant opted in" do
      participant.headshot.attach(io: StringIO.new(PNG_BYTES), filename: "headshot.png", content_type: "image/png")

      get public_profile_path(slug: participant.public_profile_slug)
      expect(response.body).not_to include("headshot.png")

      participant.update!(public_profile_show_photo: true)
      get public_profile_path(slug: participant.public_profile_slug)
      expect(response.body).to include("headshot.png")
    end

    it "works logged out and logged in" do
      get public_profile_path(slug: participant.public_profile_slug)
      expect(response).to have_http_status(:ok)
    end

    it "shows location, website, and social links when set" do
      participant.update!(
        public_profile_location: "United Kingdom",
        public_profile_website: "https://leowilkin.com",
        public_profile_github: "leowilkin",
        public_profile_bluesky: "leowilkin.com"
      )

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body).to include("United Kingdom")
      expect(response.body).to include("https://leowilkin.com")
      expect(response.body).to include("https://github.com/leowilkin")
      expect(response.body).to include("https://bsky.app/profile/leowilkin.com")
    end

    it "shows the verified badge only for HCA-verified participants" do
      get public_profile_path(slug: participant.public_profile_slug)
      expect(response.body).not_to include("Verified with Hack Club")

      participant.update!(user: create(:user, oidc_claims: { "verification_status" => "verified" }))
      get public_profile_path(slug: participant.public_profile_slug)
      expect(response.body).to include("Verified with Hack Club")
    end

    it "serves map markers as JSON and never embeds them in the page" do
      create(:participant_event, :checked_in, participant: participant,
                                              event: past_event(name: "Mapped <script> Hackathon"), status: :complete)

      get public_profile_path(slug: participant.public_profile_slug)
      expect(response.body).to include("public-profile-map")
      expect(response.body).to include("/p/#{participant.public_profile_slug}/markers")
      expect(response.body).not_to include("location_latitude")

      get public_profile_markers_path(slug: participant.public_profile_slug)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      markers = response.parsed_body
      expect(markers.length).to eq(1)
      expect(markers.first["name"]).to eq("Mapped <script> Hackathon")
      expect(markers.first["lat"]).to be_within(0.001).of(37.7749)
    end

    it "404s the markers endpoint when the profile is disabled" do
      participant.update!(public_profile_enabled: false)

      get public_profile_markers_path(slug: participant.public_profile_slug)

      expect(response).to have_http_status(:not_found)
    end

    it "prefers the uploaded profile photo over the headshot" do
      participant.update!(public_profile_show_photo: true)
      participant.headshot.attach(io: StringIO.new(PNG_BYTES), filename: "headshot.png", content_type: "image/png")
      participant.public_profile_photo.attach(io: StringIO.new(PNG_BYTES), filename: "just-for-public.png", content_type: "image/png")

      get public_profile_path(slug: participant.public_profile_slug)

      expect(response.body).to include("just-for-public.png")
      expect(response.body).not_to include("headshot.png")
    end
  end
end
