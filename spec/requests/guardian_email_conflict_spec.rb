require "rails_helper"

# A guardian sharing the participant's email address is a single inbox wearing
# two hats: the minor receives their own guardian invite, can open the portal,
# and can consent on their own behalf. Every surface that can write either
# address has to refuse the collision.
RSpec.describe "Guardian and participant email collisions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, travel_enabled: false, accommodation_enabled: false) }

  describe "participant onboarding" do
    let(:user) { create(:user) }
    let(:participant) do
      create(:participant, user: user, email: user.email, date_of_birth: 15.years.ago.to_date)
    end
    let(:participant_event) do
      create(:participant_event, participant: participant, event: event,
        status: :in_progress, onboarding_step: 99)
    end

    before do
      participant_event
      sign_in user
    end

    def submit_guardian(email:, autosave: false)
      params = {
        guardian_first_name: "Alex",
        guardian_last_name: "Guardian",
        guardian_email: email,
        guardian_phone: "+12025559876",
        guardian_relationship: "Parent"
      }
      params[:autosave] = "true" if autosave

      patch onboarding_step_path(step: "guardian", event_id: event.id), params: params
    end

    it "refuses a guardian email that matches the participant's" do
      expect { submit_guardian(email: participant.email.upcase) }
        .not_to change(Guardian, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(flash[:alert])
        .to eq("Guardian email address cannot be the same as the participant's email address.")
    end

    it "does not quietly create the guardian on autosave either" do
      expect { submit_guardian(email: participant.email, autosave: true) }
        .not_to change(Guardian, :count)
    end

    it "refuses to move the participant's own email onto their guardian's" do
      gpe = create(:guardian_participant_event, participant_event: participant_event)

      patch onboarding_step_path(step: "profile", event_id: event.id),
        params: { participant: {
          legal_first_name: participant.legal_first_name,
          legal_last_name: participant.legal_last_name,
          email: gpe.guardian.email,
          tshirt_size: "M"
        } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(flash[:alert]).to include("cannot be the same as a parent or guardian's email address")
      expect(participant.reload.email).not_to eq(gpe.guardian.email)
    end

    it "accepts a different guardian email" do
      expect { submit_guardian(email: "parent@example.com") }
        .to change(Guardian, :count).by(1)

      expect(participant_event.guardian_participant_events.count).to eq(1)
    end
  end

  describe "admin linking a guardian" do
    let(:admin) do
      User.create!(email: "admin-guardian-email@example.com", name: "Admin", global_role: "global_admin")
    end
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in admin }

    it "rejects a guardian whose email is the participant's" do
      expect {
        post link_guardian_admin_event_participant_path(event.slug, participant_event),
          params: {
            guardian_email: participant_event.participant.email.upcase,
            guardian_first_name: "Alex",
            guardian_last_name: "Guardian",
            guardian_relationship: "Parent"
          }
      }.not_to change(GuardianParticipantEvent, :count)

      expect(flash[:alert])
        .to eq("Guardian email cannot be the same as the participant's email address.")
    end

    it "rejects it on the guardian edit form too" do
      gpe = create(:guardian_participant_event, participant_event: participant_event)

      patch admin_event_participant_guardian_path(event.slug, participant_event, gpe),
        params: { guardian: {
          legal_first_name: gpe.guardian.legal_first_name,
          legal_last_name: gpe.guardian.legal_last_name,
          email: participant_event.participant.email
        } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(gpe.guardian.reload.email).not_to eq(participant_event.participant.email)
    end
  end

  describe "the guardian portal" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
    let(:token) { gpe.generate_invite_token! }

    it "refuses a guardian email change onto the participant's address" do
      patch guardian_portal_update_step_path(token: token, step: "details"),
        params: {
          guardian: {
            legal_first_name: "Alex",
            legal_last_name: "Guardian",
            email: participant_event.participant.email,
            phone: "+12025559876"
          },
          relationship: "Parent"
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(flash[:alert]).to include("cannot be the same as the participant's email address")
      expect(gpe.guardian.reload.email).not_to eq(participant_event.participant.email)
    end

    it "refuses to move the participant's email onto the guardian's address" do
      participant = participant_event.participant

      patch guardian_portal_update_step_path(token: token, step: "participant_info"),
        params: { participant: { email: gpe.guardian.email } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(flash[:alert]).to include("cannot be the same as a parent or guardian's email address")
      expect(participant.reload.email).not_to eq(gpe.guardian.email)
    end
  end
end
