require "rails_helper"

RSpec.describe "Dashboard public profile settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user, legal_first_name: "Grace", legal_last_name: "Hopper") }

  before { sign_in user }

  def past_event(attrs = {})
    create(:event, { starts_at: 3.months.ago, ends_at: 3.months.ago + 2.days,
                     registration_close_at: 4.months.ago }.merge(attrs))
  end

  describe "GET /dashboard/profile" do
    it "renders the public profile section" do
      get dashboard_profile_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Public profile")
      expect(response.body).to include("Make my profile public")
    end
  end

  describe "PATCH /dashboard/public_profile" do
    it "enables the profile and generates a slug" do
      patch dashboard_public_profile_path, params: { participant: { public_profile_enabled: "1" } }

      expect(response).to redirect_to(dashboard_profile_path)
      participant.reload
      expect(participant).to be_public_profile_enabled
      expect(participant.public_profile_slug).to eq("grace-hopper")
    end

    it "saves a custom slug, bio, and profile details" do
      patch dashboard_public_profile_path, params: {
        participant: {
          public_profile_enabled: "1",
          public_profile_slug: "gracie",
          public_profile_bio: "hi!",
          public_profile_show_photo: "1",
          public_profile_location: "Shelburne, VT",
          public_profile_github: "https://github.com/gracehopper"
        }
      }

      participant.reload
      expect(participant.public_profile_slug).to eq("gracie")
      expect(participant.public_profile_bio).to eq("hi!")
      expect(participant).to be_public_profile_show_photo
      expect(participant.public_profile_location).to eq("Shelburne, VT")
      expect(participant.public_profile_github).to eq("gracehopper")
    end

    it "uploads and removes the public profile photo without touching the headshot" do
      png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      participant.headshot.attach(io: StringIO.new(png), filename: "headshot.png", content_type: "image/png")
      headshot_blob_id = participant.headshot.blob.id

      patch dashboard_public_profile_path, params: {
        participant: {
          public_profile_photo: Rack::Test::UploadedFile.new(StringIO.new(png), "image/png", original_filename: "new-photo.png")
        }
      }

      participant.reload
      expect(participant.public_profile_photo).to be_attached
      expect(participant.headshot.blob.id).to eq(headshot_blob_id)

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "0" },
        remove_public_profile_photo: "1"
      }

      perform_enqueued_jobs if respond_to?(:perform_enqueued_jobs)
      expect(participant.reload.headshot).to be_attached
    end

    it "rejects a slug that is already taken" do
      create(:participant, public_profile_slug: "taken")

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "1", public_profile_slug: "taken" }
      }

      expect(response).to redirect_to(dashboard_profile_path)
      expect(flash[:alert]).to be_present
      expect(participant.reload.public_profile_slug).not_to eq("taken")
    end

    it "updates per-event visibility from the checked boxes" do
      visible = create(:participant_event, :checked_in, participant: participant, event: past_event, status: :complete)
      hidden = create(:participant_event, :checked_in, participant: participant, event: past_event, status: :complete)

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "1" },
        visible_participant_event_ids: [ visible.id ]
      }

      expect(visible.reload.hidden_from_public_profile).to be(false)
      expect(hidden.reload.hidden_from_public_profile).to be(true)
    end

    it "updates staffed-event visibility from the checked boxes, covering every role on the event" do
      visible_event = past_event
      hidden_event = past_event
      create(:event_role_assignment, user: user, event: visible_event, hidden_from_public_profile: true)
      visible_second_role = create(:event_role_assignment, user: user, event: visible_event, role: "event_admin",
                                                           hidden_from_public_profile: true)
      hidden_assignment = create(:event_role_assignment, user: user, event: hidden_event)

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "1" },
        visible_staff_event_ids: [ visible_event.id ]
      }

      expect(visible_event.event_role_assignments.pluck(:hidden_from_public_profile)).to all(be(false))
      expect(visible_second_role.reload.hidden_from_public_profile).to be(false)
      expect(hidden_assignment.reload.hidden_from_public_profile).to be(true)
    end

    it "cannot touch another user's staff assignments" do
      other = create(:event_role_assignment, event: past_event, hidden_from_public_profile: false)
      create(:event_role_assignment, user: user, event: past_event)

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "1" },
        visible_staff_event_ids: []
      }

      expect(other.reload.hidden_from_public_profile).to be(false)
    end

    it "cannot touch another participant's events" do
      other = create(:participant_event, :checked_in, event: past_event, status: :complete, hidden_from_public_profile: true)
      create(:participant_event, :checked_in, participant: participant, event: past_event, status: :complete)

      patch dashboard_public_profile_path, params: {
        participant: { public_profile_enabled: "1" },
        visible_participant_event_ids: [ other.id ]
      }

      expect(other.reload.hidden_from_public_profile).to be(true)
    end
  end
end
