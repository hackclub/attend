require "rails_helper"

RSpec.describe "Onboarding profile autosave", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, preferred_name: "Old") }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 0)
  end

  before { sign_in user }

  def autosave(params)
    patch onboarding_step_path(step: "profile", event_id: event.id),
          params: params.merge(autosave: "true")
  end

  it "saves the text fields" do
    autosave(participant: { preferred_name: "New" })

    expect(response).to have_http_status(:ok)
    expect(participant.reload.preferred_name).to eq("New")
  end

  # Re-attaching on every autosave purges and recreates the attachment row, which
  # deadlocks when two autosaves overlap (ATTEND-9M).
  it "ignores a headshot upload" do
    autosave(participant: {
      preferred_name: "New",
      headshot: fixture_file_upload("headshot.png", "image/png")
    })

    expect(response).to have_http_status(:ok)
    participant.reload
    expect(participant.preferred_name).to eq("New")
    expect(participant.headshot).not_to be_attached
  end

  it "leaves an already-attached headshot in place" do
    participant.headshot.attach(
      io: Rails.root.join("spec/fixtures/files/headshot.png").open,
      filename: "headshot.png",
      content_type: "image/png"
    )
    original_id = participant.headshot_attachment.id

    autosave(participant: {
      preferred_name: "New",
      headshot: fixture_file_upload("headshot.png", "image/png")
    })

    expect(response).to have_http_status(:ok)
    participant.reload
    expect(participant.headshot).to be_attached
    expect(participant.headshot_attachment.id).to eq(original_id)
  end

  it "attaches the headshot on a real (non-autosave) submit" do
    patch onboarding_step_path(step: "profile", event_id: event.id), params: {
      participant: {
        tshirt_size: participant.tshirt_size.presence || "m",
        headshot: fixture_file_upload("headshot.png", "image/png")
      }
    }

    expect(participant.reload.headshot).to be_attached
  end
end
