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

  # A blob as the browser leaves it after a direct upload: stored, unchecked,
  # labelled with whatever the browser claimed, attached to nothing.
  def direct_upload(bytes = Rails.root.join("spec/fixtures/files/headshot.png").binread, filename: "headshot.png", content_type: "image/png")
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: filename, byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes), content_type: content_type
    ).tap { |blob| blob.upload_without_unfurling(StringIO.new(bytes)) }
  end

  def stage_direct(blob_or_signed_id)
    signed_id = blob_or_signed_id.is_a?(ActiveStorage::Blob) ? blob_or_signed_id.signed_id : blob_or_signed_id
    post onboarding_stage_headshot_path(event_id: event.id), params: { signed_blob_id: signed_id }
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

  describe "staging a photo the browser uploaded directly" do
    it "stages the stored blob without uploading anything" do
      blob = direct_upload

      expect { stage_direct(blob) }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("success" => true, "signed_id" => be_present)
      expect(ActiveStorage::Blob.find_signed(response.parsed_body["signed_id"], purpose: "onboarding_headshot:#{participant.id}")).to eq(blob)
      expect(blob.reload.attachments).to be_empty
    end

    it "works end to end through Rails' direct upload endpoint" do
      bytes = Rails.root.join("spec/fixtures/files/headshot.png").binread
      checksum = OpenSSL::Digest::MD5.base64digest(bytes)
      post rails_direct_uploads_path,
           params: { blob: { filename: "headshot.png", byte_size: bytes.bytesize, checksum: checksum, content_type: "image/png" } },
           as: :json
      expect(response).to have_http_status(:ok)
      upload = response.parsed_body

      # What the browser does next: PUT the bytes to the signed URL (the Disk
      # service in test; the R2 bucket in production).
      put URI(upload["direct_upload"]["url"]).request_uri, params: bytes, headers: upload["direct_upload"]["headers"]
      expect(response).to have_http_status(:no_content)

      stage_direct(upload["signed_id"])
      expect(response).to have_http_status(:ok)
      submit_profile(staged_headshot: response.parsed_body["signed_id"])

      expect(participant.reload.headshot.blob.checksum).to eq(checksum)
      expect(participant.headshot.blob.content_type).to eq("image/png")
    end

    it "schedules the photo to be purged if it's never submitted" do
      blob = direct_upload

      freeze_time do
        stage_direct(blob)

        expect(ActiveStorage::PurgeJob)
          .to have_been_enqueued.with(blob).at(OnboardingController::STAGED_HEADSHOT_TTL.from_now)
      end
    end

    it "attaches it when the profile is submitted" do
      blob = direct_upload
      stage_direct(blob)

      submit_profile(staged_headshot: response.parsed_body["signed_id"])

      expect(response).to redirect_to(onboarding_step_path(step: "travel", event_id: event.id))
      expect(participant.reload.headshot.blob).to eq(blob)
    end

    it "doesn't read the photo back from storage again on submit" do
      blob = direct_upload
      stage_direct(blob)
      signed_id = response.parsed_body["signed_id"]
      allow(ActiveStorage::Blob.service).to receive(:download_chunk).and_call_original
      allow(ActiveStorage::Blob.service).to receive(:download).and_call_original

      submit_profile(staged_headshot: signed_id)

      expect(participant.reload.headshot.blob).to eq(blob)
      expect(ActiveStorage::Blob.service).not_to have_received(:download_chunk)
      expect(ActiveStorage::Blob.service).not_to have_received(:download)
    end

    it "judges the type by the stored bytes, not the browser's label" do
      blob = direct_upload("%PDF-1.4\n%fake document\n", filename: "headshot.png", content_type: "image/png")

      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { stage_direct(blob) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include("success" => false, "error" => "Headshot must be a JPEG, PNG, or WebP image")
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it "rejects and deletes a stored file that won't open as an image" do
      blob = direct_upload("\x89PNG\r\n\x1a\n but not really")

      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { stage_direct(blob) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("could not be read as an image")
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it "rejects a photo over the size limit" do
      blob = direct_upload
      blob.update_columns(byte_size: 11.megabytes)

      stage_direct(blob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Headshot must be less than 10MB")
    end

    it "won't stage a blob that's already someone's photo" do
      someone = create(:participant)
      someone.headshot.attach(io: Rails.root.join("spec/fixtures/files/headshot.png").open, filename: "theirs.png", content_type: "image/png")
      their_blob = someone.headshot.blob

      perform_enqueued_jobs(only: ActiveStorage::PurgeJob) { stage_direct(their_blob) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("expired")
      expect(someone.reload.headshot.blob).to eq(their_blob)
      expect(ActiveStorage::Blob.exists?(their_blob.id)).to be(true)
    end

    it "won't stage an upload older than a day" do
      blob = direct_upload
      blob.update_columns(created_at: (DirectUploadedBlobs::DIRECT_UPLOAD_MAX_AGE + 1.minute).ago)

      stage_direct(blob)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("expired")
    end

    it "won't take a tampered signed id" do
      stage_direct("not-a-signed-id")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["success"]).to be(false)
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

    it "won't attach someone else's photo from a signed id posted as the headshot" do
      someone = create(:participant)
      someone.headshot.attach(io: Rails.root.join("spec/fixtures/files/headshot.png").open,
                              filename: "theirs.png", content_type: "image/png")

      submit_profile(participant: { headshot: someone.headshot.blob.signed_id })

      expect(participant.reload.headshot).not_to be_attached
      expect(someone.reload.headshot).to be_attached
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
