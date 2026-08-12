require "rails_helper"

RSpec.describe "Admin::Participants merge", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-merge@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:primary) { create(:participant) }
  let!(:participant_event) { create(:participant_event, participant: primary, event: event, status: :complete) }
  let(:duplicate) { create(:participant, legal_first_name: "Distinctive", legal_last_name: "Duplicate", slack_user_id: "U999") }

  describe "GET merge" do
    before { sign_in global_admin }

    it "lists candidates matching the search" do
      duplicate
      non_match = create(:participant, legal_first_name: "Unrelated", legal_last_name: "Person")

      get merge_admin_event_participant_path(event.slug, participant_event), params: { q: "Distinctive" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Distinctive")
      expect(response.body).to include(duplicate.email)
      expect(response.body).not_to include(non_match.email)
    end

    it "previews the merge for a selected duplicate" do
      get merge_admin_event_participant_path(event.slug, participant_event), params: { duplicate_id: duplicate.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("slack user")
    end
  end

  describe "POST merge_duplicate" do
    it "merges the duplicate into this participant and audit-logs it" do
      sign_in global_admin
      duplicate

      expect {
        post merge_duplicate_admin_event_participant_path(event.slug, participant_event),
          params: { duplicate_id: duplicate.id }
      }.to change(Participant, :count).by(-1)

      expect(response).to redirect_to(admin_event_participant_path(event.slug, participant_event))
      expect(primary.reload.slack_user_id).to eq("U999")

      log = AuditLog.where(action: "merge_duplicate").order(:created_at).last
      expect(log).to be_present
      expect(log.record_id).to eq(primary.id)
      expect(log.actor).to eq(global_admin)
    end

    it "refuses to merge the participant into itself" do
      sign_in global_admin

      expect {
        post merge_duplicate_admin_event_participant_path(event.slug, participant_event),
          params: { duplicate_id: primary.id }
      }.not_to change(Participant, :count)

      expect(flash[:alert]).to be_present
    end
  end

  describe "authorization" do
    it "is denied for event admins" do
      event_admin = create(:user)
      event_admin.event_role_assignments.create!(event: event, role: "event_admin")
      sign_in event_admin
      duplicate

      get merge_admin_event_participant_path(event.slug, participant_event)
      expect(flash[:alert]).to include("not authorized")

      expect {
        post merge_duplicate_admin_event_participant_path(event.slug, participant_event),
          params: { duplicate_id: duplicate.id }
      }.not_to change(Participant, :count)
      expect(flash[:alert]).to include("not authorized")
    end
  end
end
