require "rails_helper"

# Integrations invite with whatever birthday they were sent, even one that
# ages the participant out (see ParticipantEvent#skip_age_check). Onboarding
# then holds them on the profile step with the birthday locked; only staff can
# change it, through a change request.
RSpec.describe "Onboarding age limit", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:aged_out_birthday) { event.ends_at.to_date - 25.years }
  let(:participant) { create(:participant, user: user, date_of_birth: aged_out_birthday, tshirt_size: "m") }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress,
      onboarding_step: 0, onboarding_intro_seen_at: Time.current, skip_age_check: true)
  end

  before { sign_in user }

  def profile_path
    onboarding_step_path(step: "profile", event_id: event.id)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  it "shows the hold with the birthday locked" do
    get profile_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css("[data-testid='age-limit-hold']")).to be_present
    expect(document.at_css("input[name='participant[date_of_birth]']")["disabled"]).to be_present
  end

  it "keeps them off every later step" do
    participant_event.update!(onboarding_step: 3)

    get onboarding_step_path(step: "health", event_id: event.id)
    expect(response).to redirect_to(profile_path)

    patch onboarding_step_path(step: "health", event_id: event.id), params: { medical: { allergies: "None" } }
    expect(response).to redirect_to(profile_path)

    post complete_onboarding_path(event_id: event.id), params: { code_of_conduct_accepted: "1", code_of_conduct_signature: "Me" }
    expect(response).to redirect_to(profile_path)
    expect(participant_event.reload.code_of_conduct_accepted_at).to be_nil
  end

  it "ignores a birthday changed on the profile form" do
    patch profile_path, params: { participant: { tshirt_size: "m", date_of_birth: "2011-05-05" } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(participant.reload.date_of_birth).to eq(aged_out_birthday)
    expect(participant_event.reload.onboarding_step).to eq(0)
  end

  it "ignores a birthday changed by autosave" do
    patch profile_path, params: { autosave: "true", participant: { preferred_name: "Sam", date_of_birth: "2011-05-05" } }

    expect(response).to have_http_status(:ok)
    expect(participant.reload).to have_attributes(preferred_name: "Sam", date_of_birth: aged_out_birthday)
  end

  # Rails also accepts a date as separate year, month and day params.
  describe "with the birthday sent in parts" do
    let(:date_parts) { { "date_of_birth(1i)" => "2011", "date_of_birth(2i)" => "5", "date_of_birth(3i)" => "5" } }

    it "ignores it on the profile form" do
      patch profile_path, params: { participant: { tshirt_size: "m", **date_parts } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(participant.reload.date_of_birth).to eq(aged_out_birthday)
      expect(participant_event.reload.onboarding_step).to eq(0)
    end

    it "ignores it on autosave" do
      patch profile_path, params: { autosave: "true", participant: { preferred_name: "Sam", **date_parts } }

      expect(response).to have_http_status(:ok)
      expect(participant.reload).to have_attributes(preferred_name: "Sam", date_of_birth: aged_out_birthday)
    end
  end

  context "with a birthday under the limit" do
    let(:participant) { create(:participant, user: user, date_of_birth: 16.years.ago.to_date, tshirt_size: "m") }

    it "doesn't autosave a half-typed year that would age them out" do
      original = participant.date_of_birth

      patch profile_path, params: { autosave: "true", participant: { preferred_name: "Sam", date_of_birth: "0200-05-05" } }

      expect(response).to have_http_status(:ok)
      expect(participant.reload).to have_attributes(preferred_name: "Sam", date_of_birth: original)
    end

    it "saves a submitted birthday that ages them out, then holds them" do
      patch profile_path, params: { participant: { tshirt_size: "m", date_of_birth: aged_out_birthday.iso8601 } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(participant.reload.date_of_birth).to eq(aged_out_birthday)
      expect(participant_event.reload.onboarding_step).to eq(0)
      expect(document.at_css("[data-testid='age-limit-hold']")).to be_present
    end

    it "lets them continue as before" do
      patch profile_path, params: { participant: { tshirt_size: "m" } }

      expect(participant_event.reload.onboarding_step).to eq(1)
    end
  end

  describe "asking staff for a correction" do
    let(:staff) { create(:user) }

    before { create(:event_role_assignment, event: event, user: staff, role: :event_admin) }

    def request_correction(date_of_birth)
      post dashboard_event_registration_change_requests_path(participant_event), params: {
        return_to: "onboarding",
        registration_change_request: {
          kind: "signed_identity",
          requested_changes: { date_of_birth: date_of_birth },
          requester_note: "Typed the wrong year"
        }
      }
    end

    it "sends it to staff and comes back to the profile step" do
      expect { request_correction("2010-05-05") }
        .to have_enqueued_mail(RegistrationCorrectionMailer, :staff_notification)

      expect(response).to redirect_to(profile_path)
      change_request = participant_event.registration_change_requests.last
      expect(change_request).to have_attributes(kind: "signed_identity", status: "pending")
      expect(change_request.requested_changes).to eq("date_of_birth" => "2010-05-05")
      expect(participant.reload.date_of_birth).to eq(aged_out_birthday)

      get profile_path
      expect(document.at_css("[data-testid='age-limit-hold']").text).to include("You've asked staff to correct it")
    end

    it "lets them continue once staff approve it" do
      request_correction("2010-05-05")
      RegistrationChangeRequests::Approve.call(request: participant_event.registration_change_requests.last, reviewer: staff)

      patch profile_path, params: { participant: { tshirt_size: "m" } }

      expect(participant.reload.date_of_birth).to eq(Date.new(2010, 5, 5))
      expect(participant_event.reload.onboarding_step).to eq(1)
    end

    it "doesn't show staff's internal note when approval needs a manual reset" do
      past_event = create(:event, starts_at: 8.years.ago, ends_at: 8.years.ago + 2.days)
      create(:participant_event, participant: participant, event: past_event, code_of_conduct_accepted_at: 8.years.ago)
      request_correction("2010-05-05")
      result = RegistrationChangeRequests::Approve.call(request: participant_event.registration_change_requests.last, reviewer: staff)
      expect(result).to eq(:follow_up_needed)

      get profile_path

      hold = document.at_css("[data-testid='age-limit-hold']")
      expect(hold.text).to include("Staff need to check a few things")
      expect(hold.text).not_to include("This identity is shared")
      expect(hold.at_css("form")).to be_nil
    end

    it "shows what staff wrote when they ask for more" do
      request_correction("2010-05-05")
      participant_event.registration_change_requests.last
        .update!(status: :follow_up_needed, staff_response: "Can you send a photo of your ID?", resolved_by: staff, resolved_at: Time.current)

      get profile_path

      hold = document.at_css("[data-testid='age-limit-hold']")
      expect(hold.text).to include("Staff replied to your last request: Can you send a photo of your ID?")
      expect(hold.at_css("form")).to be_present
    end
  end
end
