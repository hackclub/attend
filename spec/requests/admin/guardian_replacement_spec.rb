require "rails_helper"

# Global admins can swap a guardian for a different person from the admin
# participant page (Guardians::Replace). Event admins can't.
RSpec.describe "Admin guardian replacement", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant_event) do
    fill_in_registration_answers(create(:participant_event, event: event)).tap do |pe|
      pe.update!(status: :complete, code_of_conduct_accepted_at: 1.day.ago)
    end
  end
  let(:old_guardian) { create(:guardian, legal_first_name: "Pat", legal_last_name: "Wrongparent") }
  let!(:old_link) do
    create(:guardian_participant_event, participant_event: participant_event, guardian: old_guardian,
      status: :completed, is_primary_guardian: true)
  end
  let!(:waiver) do
    Consent.create!(participant_event: participant_event, guardian_participant_event: old_link,
      consent_type: :waiver, status: :signed, guardian_signed_at: 1.day.ago, signed_at: 1.day.ago)
  end
  let(:global_admin) { User.create!(email: "replace-admin@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:event_admin) do
    User.create!(email: "replace-event-admin@example.com", name: "Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end
  let(:new_guardian_params) do
    { guardian: { legal_first_name: "Robin", legal_last_name: "Rightparent", email: "robin@example.com",
                  phone: "+12025550188", relationship: "Parent" } }
  end

  [ true ].each do |console|
    context(console ? "in the console UI" : "in the original admin UI") do
      def participant_page = admin_event_participant_path(event, participant_event)
      def replace_path = replace_admin_event_participant_guardian_path(event, participant_event, old_link)

      context "as a global admin" do
        before do
          sign_in global_admin
        end

        it "links to the replacement form from the participant page" do
          get participant_page

          expect(response).to have_http_status(:ok)
          expect(response.body).to include(replace_path)
        end

        it "shows the form with what will be discarded" do
          get replace_path

          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Replace guardian", "Pat Wrongparent", waiver.display_name)
        end

        it "swaps the guardian, resets the waiver and emails the new guardian" do
          get participant_page # warm-up: the first POST after sign-in audit-logs the user

          expect { post replace_path, params: new_guardian_params }
            .to have_enqueued_mail(GuardianMailer, :invitation)

          expect(response).to redirect_to(participant_page)
          follow_redirect!
          expect(response.body).to include("Robin Rightparent is now the guardian", "Portal invite sent to robin@example.com")

          new_link = participant_event.guardian_participant_events.reload.sole
          expect(new_link.guardian.email).to eq("robin@example.com")
          expect(GuardianParticipantEvent.exists?(old_link.id)).to be(false)
          expect(waiver.reload).to be_pending
          expect(AuditLog.where(action: "replace_guardian").sole.record).to eq(new_link)
        end

        it "re-renders the form with the error when the details don't validate" do
          get participant_page

          post replace_path, params: { guardian: new_guardian_params[:guardian].merge(email: participant_event.participant.email) }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("participant&#39;s email")
          expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
          expect(waiver.reload).to be_signed
        end
      end

      context "as an event admin" do
        before do
          sign_in event_admin
        end

        it "doesn't offer the replacement" do
          get participant_page

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include(replace_path)
        end

        it "can't open the form or submit it" do
          get replace_path
          expect(response).to have_http_status(:redirect)

          get participant_page
          post replace_path, params: new_guardian_params

          expect(response).to have_http_status(:redirect)
          expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
          expect(waiver.reload).to be_signed
        end
      end
    end
  end
end
