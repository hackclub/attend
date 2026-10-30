require "rails_helper"

# The profile step uploads a headshot as soon as it's picked (see
# headshot_upload_controller.js), but only attaches it when the profile is
# submitted.
RSpec.describe "Onboarding headshot upload", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, tshirt_size: "m") }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 0)
  end

  before { sign_in user }

  def stage(file)
    post onboarding_stage_headshot_path(event_id: event.id), params: { headshot: file }
  end

  def stage_photo
    stage(fixture_file_upload("headshot.png", "image/png"))
    response.parsed_body["signed_id"]
  end

  def submit_profile(params = {})
    patch onboarding_step_path(step: "profile", event_id: event.id),
          params: { participant: { tshirt_size: "m" } }.deep_merge(params)
  end

  def attach_old_headshot
    participant.headshot.attach(
      io: Rails.root.join("spec/fixtures/files/headshot.png").open,
      filename: "old.png",
      content_type: "image/png"
    )
    participant.headshot.blob
  end

  describe "staging" do
    it "stores the photo without attaching it" do
      expect { stage(fixture_file_upload("headshot.png", "image/png")) }
        .to change(ActiveStorage::Blob, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("success" => true, "signed_id" => be_present)
      expect(participant.reload.headshot).not_to be_attached
      expect(ActiveStorage::Blob.last.attachments).to be_empty
    end

    it "schedules the photo to be purged if it's never submitted" do
      freeze_time do
        stage(fixture_file_upload("headshot.png", "image/png"))

        expect(ActiveStorage::PurgeJob)
          .to have_been_enqueued.with(ActiveStorage::Blob.last).at(OnboardingController::STAGED_HEADSHOT_TTL.from_now)
      end
    end

    it "leaves the current headshot in place" do
      old_blob = attach_old_headshot

      stage(fixture_file_upload("headshot.png", "image/png"))

      expect(participant.reload.headshot.blob).to eq(old_blob)
    end

    it "rejects a file that isn't an allowed image type" do
      expect { stage(fixture_file_upload("evidence.txt", "text/plain")) }
        .not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("success" => false, "error" => "Headshot must be a JPEG, PNG, or WebP image")
    end

    it "rejects a file that won't open as an image" do
      file = Rack::Test::UploadedFile.new(StringIO.new("not a png at all"), "image/png", original_filename: "headshot.png")

      expect { stage(file) }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("could not be read as an image")
    end

    it "asks for a photo when none was sent" do
      post onboarding_stage_headshot_path(event_id: event.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("success" => false, "error" => "Please choose a photo.")
    end

    it "still works for someone held at the profile step by the age limit" do
      participant.update!(date_of_birth: event.ends_at.to_date - 25.years)
      participant_event.update!(skip_age_check: true)

      stage(fixture_file_upload("headshot.png", "image/png"))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
    end
  end

  describe "submitting the profile" do
    it "attaches the staged photo" do
      signed_id = stage_photo
      staged_blob = ActiveStorage::Blob.last

      submit_profile(staged_headshot: signed_id)

      expect(response).to redirect_to(onboarding_step_path(step: "travel", event_id: event.id))
      expect(participant.reload.headshot.blob).to eq(staged_blob)
    end

    it "replaces the current headshot and purges the old one" do
      old_blob = attach_old_headshot
      signed_id = stage_photo
      staged_blob = ActiveStorage::Blob.last

      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { submit_profile(staged_headshot: signed_id) }

      expect(participant.reload.headshot.blob).to eq(staged_blob)
      expect(ActiveStorage::Blob.exists?(old_blob.id)).to be(false)
    end

    it "keeps the photo when its cleanup job runs after it was submitted" do
      signed_id = stage_photo
      staged_blob = ActiveStorage::Blob.last
      submit_profile(staged_headshot: signed_id)

      ActiveStorage::PurgeJob.perform_now(staged_blob)

      expect(participant.reload.headshot.blob).to eq(staged_blob)
      expect(ActiveStorage::Blob.exists?(staged_blob.id)).to be(true)
    end

    it "prefers a photo sent with the form" do
      signed_id = stage_photo
      staged_blob = ActiveStorage::Blob.last

      submit_profile(staged_headshot: signed_id, participant: { headshot: fixture_file_upload("headshot.png", "image/png") })

      expect(participant.reload.headshot).to be_attached
      expect(participant.headshot.blob).not_to eq(staged_blob)
    end

    it "keeps the staged photo in the form when something else stops the save" do
      signed_id = stage_photo

      submit_profile(staged_headshot: signed_id, participant: { tshirt_size: "" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(participant.reload.headshot).not_to be_attached
      form = Nokogiri::HTML(response.body)
      expect(form.at_css("input[name='staged_headshot']")["value"]).to eq(signed_id)
      expect(form.at_css("input[name='participant[headshot]']")["required"]).to be_nil
    end

    it "asks for the photo again once the staged one has expired" do
      old_blob = attach_old_headshot
      signed_id = stage_photo

      travel OnboardingController::STAGED_HEADSHOT_TTL + 1.minute do
        submit_profile(staged_headshot: signed_id)
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash[:alert]).to include("expired")
      expect(participant.reload.headshot.blob).to eq(old_blob)
    end

    it "won't attach a photo staged by someone else" do
      other_user = create(:user)
      other_participant = create(:participant, user: other_user)
      create(:participant_event, participant: other_participant, event: event, status: :in_progress, onboarding_step: 0)
      sign_in other_user
      signed_id = stage_photo
      sign_in user

      submit_profile(staged_headshot: signed_id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(participant.reload.headshot).not_to be_attached
    end

    it "ignores a staged photo on autosave" do
      signed_id = stage_photo

      patch onboarding_step_path(step: "profile", event_id: event.id),
            params: { autosave: "true", staged_headshot: signed_id, participant: { preferred_name: "New" } }

      expect(response).to have_http_status(:ok)
      expect(participant.reload.preferred_name).to eq("New")
      expect(participant.headshot).not_to be_attached
    end
  end
end
