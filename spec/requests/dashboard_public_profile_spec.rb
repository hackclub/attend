require "rails_helper"

RSpec.describe "Dashboard public profile settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }
  let!(:participant) { create(:participant, user: user, legal_first_name: "Grace", legal_last_name: "Hopper") }

  before { sign_in user }

  def png_bytes
    Rails.root.join("spec/fixtures/files/headshot.png").binread
  end

  # A blob as the browser leaves it after a direct upload: stored, unchecked,
  # attached to nothing.
  def direct_upload(bytes = png_bytes, content_type: "image/png")
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: "photo.png", byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes), content_type: content_type
    ).tap { |blob| blob.upload_without_unfurling(StringIO.new(bytes)) }
  end

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

    describe "with a photo the browser uploaded directly" do
      include ActiveJob::TestHelper

      it "attaches the stored blob" do
        blob = direct_upload

        expect {
          patch dashboard_public_profile_path, params: { participant: { public_profile_bio: "hi" }, public_profile_photo_signed_blob_id: blob.signed_id }
        }.not_to change(ActiveStorage::Blob, :count)

        expect(response).to redirect_to(dashboard_profile_path)
        expect(flash[:notice]).to be_present
        expect(participant.reload.public_profile_photo.blob).to eq(blob)
        expect(participant.public_profile_bio).to eq("hi")
      end

      it "refuses and deletes a stored file that won't open as an image" do
        blob = direct_upload("\x89PNG\r\n\x1a\n but not really")

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          patch dashboard_public_profile_path, params: { participant: { public_profile_bio: "hi" }, public_profile_photo_signed_blob_id: blob.signed_id }
        end

        expect(flash[:alert]).to include("could not be read as an image")
        expect(participant.reload.public_profile_photo).not_to be_attached
        expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
      end

      it "judges the type by the stored bytes, not the browser's label" do
        blob = direct_upload("%PDF-1.4\n%fake document\n")

        patch dashboard_public_profile_path, params: { participant: { public_profile_bio: "hi" }, public_profile_photo_signed_blob_id: blob.signed_id }

        expect(flash[:alert]).to include("must be a JPEG, PNG, or WebP image")
        expect(participant.reload.public_profile_photo).not_to be_attached
      end

      it "won't attach a blob that's already someone else's photo" do
        someone = create(:participant)
        someone.headshot.attach(io: StringIO.new(png_bytes), filename: "theirs.png", content_type: "image/png")
        their_blob = someone.headshot.blob

        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          patch dashboard_public_profile_path, params: { participant: { public_profile_bio: "hi" }, public_profile_photo_signed_blob_id: their_blob.signed_id }
        end

        expect(flash[:alert]).to include("expired")
        expect(participant.reload.public_profile_photo).not_to be_attached
        expect(someone.reload.headshot.blob).to eq(their_blob)
      end

      it "ignores a signed blob id sent in place of the file" do
        someone = create(:participant)
        someone.headshot.attach(io: StringIO.new(png_bytes), filename: "theirs.png", content_type: "image/png")

        patch dashboard_public_profile_path, params: { participant: { public_profile_bio: "hi", public_profile_photo: someone.headshot.blob.signed_id } }

        expect(response).to redirect_to(dashboard_profile_path)
        expect(participant.reload.public_profile_bio).to eq("hi")
        expect(participant.public_profile_photo).not_to be_attached
      end

      it "still takes a posted file when the direct upload didn't happen" do
        patch dashboard_public_profile_path, params: {
          participant: { public_profile_photo: Rack::Test::UploadedFile.new(StringIO.new(png_bytes), "image/png", original_filename: "photo.png") },
          public_profile_photo_signed_blob_id: ""
        }

        expect(response).to redirect_to(dashboard_profile_path)
        expect(participant.reload.public_profile_photo).to be_attached
      end
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
