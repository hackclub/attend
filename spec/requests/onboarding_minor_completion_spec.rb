require "rails_helper"

# A guardian can finish their whole side — waiver plus portal — before the
# participant gets round to hitting submit. Every `mark_complete_if_eligible!`
# hook fires on the guardian's actions and bails on the not-yet-accepted code
# of conduct, so submitting has to be the thing that re-checks. When it didn't,
# these rows sat at `awaiting_guardian` forever and the dashboard hid their
# boarding pass (it gates the QR on the raw `complete?` enum, not display_status).
RSpec.describe "Onboarding completion for minors", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:participant) do
    create(:participant, user: user, email: user.email, date_of_birth: 15.years.ago.to_date)
  end
  let(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :in_progress, onboarding_step: 99)
  end

  before { sign_in user }

  def submit
    post complete_onboarding_path(event_id: event.id),
      params: { code_of_conduct_accepted: "1", code_of_conduct_signature: "Test Minor" }
  end

  context "when the guardian finished everything first" do
    before do
      create(:guardian_participant_event, participant_event: participant_event, status: :completed)
      create(:consent, :signed, participant_event: participant_event)
      create(:consent, :freedom_waiver, :signed, participant_event: participant_event)
    end

    it "completes the participant on submit instead of parking them at awaiting_guardian" do
      expect { submit }.to change { participant_event.reload.status }.to("complete")

      expect(participant_event.onboarding_completed_at).to be_present
      expect(response).to redirect_to(onboarding_done_path(event_id: event.id))
    end

    it "does not invite the guardian who has already finished" do
      # :never_sent so an invite would actually be enqueued if submit fell
      # through to the "waiver already signed" branch instead of completing.
      participant_event.guardian_participant_events.update_all(invite_token_sent_at: nil)
      allow(GuardianMailer).to receive(:invitation).and_call_original

      submit

      expect(GuardianMailer).not_to have_received(:invitation)
    end

    context "and the event's guardian invites are locked" do
      let(:event) { create(:event, guardian_invites_locked: true) }

      it "still completes them rather than promising a waiver that is already signed" do
        expect { submit }.to change { participant_event.reload.status }.to("complete")
      end
    end
  end

  context "when the guardian still has work to do" do
    before do
      create(:guardian_participant_event, participant_event: participant_event, status: :pending)
    end

    it "parks the participant at awaiting_guardian" do
      expect { submit }.to change { participant_event.reload.status }.to("awaiting_guardian")

      expect(participant_event.onboarding_completed_at).to be_nil
    end
  end

  context "when the freedom waiver is still outstanding" do
    before do
      create(:guardian_participant_event, participant_event: participant_event, status: :completed)
      create(:consent, :signed, participant_event: participant_event)
    end

    it "parks the participant at awaiting_guardian" do
      expect { submit }.to change { participant_event.reload.status }.to("awaiting_guardian")
    end
  end

  # Staff sometimes move a registration on by hand before the participant has
  # submitted. The onboarding lock used to treat that as "already submitted"
  # and bounce them to the dashboard, so they could never reach the code of
  # conduct and the registration could never complete.
  context "when staff set the status before the participant submitted" do
    before do
      create(:guardian_participant_event, participant_event: participant_event, status: :completed)
      create(:consent, :signed, participant_event: participant_event)
      create(:consent, :freedom_waiver, :signed, participant_event: participant_event)
    end

    it "lets an awaiting_guardian participant back in to submit, then completes them" do
      participant_event.update!(status: :awaiting_guardian)

      get onboarding_step_path(step: "review", event_id: event.id)
      expect(response).to have_http_status(:ok)

      expect { submit }.to change { participant_event.reload.status }.to("complete")
      expect(participant_event.code_of_conduct_accepted_at).to be_present
    end

    it "lets a hand-completed participant sign without undoing the completion" do
      participant_event.update!(status: :complete)

      get onboarding_step_path(step: "review", event_id: event.id)
      expect(response).to have_http_status(:ok)

      submit
      expect(participant_event.reload).to be_complete
      expect(participant_event.code_of_conduct_accepted_at).to be_present
    end

    it "keeps a hand-completed participant out of the other steps" do
      participant_event.update!(status: :complete)

      get onboarding_step_path(step: "profile", event_id: event.id)
      expect(response).to redirect_to(onboarding_step_path(step: "review", event_id: event.id))

      patch onboarding_step_path(step: "profile", event_id: event.id),
        params: { participant: { date_of_birth: 30.years.ago.to_date } }
      expect(response).to redirect_to(onboarding_step_path(step: "review", event_id: event.id))
      expect(participant.reload.date_of_birth).to eq(15.years.ago.to_date)
    end
  end

  context "when the participant has already submitted" do
    before do
      create(:guardian_participant_event, participant_event: participant_event, status: :pending)
      participant_event.update!(status: :awaiting_guardian, code_of_conduct_accepted_at: 1.day.ago,
        code_of_conduct_signature: "Test Minor")
    end

    it "still locks the registration" do
      get onboarding_step_path(step: "review", event_id: event.id)

      expect(response).to redirect_to(dashboard_path)
      expect(flash[:alert]).to include("cannot be edited")
    end
  end
end
