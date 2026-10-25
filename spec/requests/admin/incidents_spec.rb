require "rails_helper"

RSpec.describe "Admin::Incidents", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-incidents@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:staff) { create(:user) }
  let(:participant_event) { create(:participant_event, event: event) }

  before { sign_in global_admin }

  describe "POST create" do
    it "records dispensed medication on a medical incident" do
      expect {
        post admin_event_incidents_path(event.slug), params: {
          incident: {
            category: "medical", severity: "low", status: "open",
            participant_event_ids: [ participant_event.id ],
            helping_staff_ids: [ staff.id ],
            medication_dispensed: "1",
            medications_attributes: { "0" => { name: "Paracetamol", dose: "2 x 500mg", notes: "After lunch" } }
          }
        }
      }.to change(IncidentMedication, :count).by(1)

      incident = Incident.last
      expect(response).to redirect_to(admin_event_incident_path(event, incident))
      expect(incident.medication_dispensed).to be(true)

      get admin_event_incident_path(event.slug, incident)
      expect(response.body).to include("Paracetamol", "2 x 500mg", "After lunch")
    end

    it "rejects a medical incident without a participant or staff member" do
      expect {
        post admin_event_incidents_path(event.slug), params: {
          incident: { category: "medical", severity: "low", status: "open" }
        }
      }.not_to change(Incident, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Medical incidents must be linked to at least one participant")
      expect(response.body).to include("Medical incidents must be linked to at least one staff member")
    end
  end

  describe "GET new" do
    it "renders the medication fields" do
      get new_admin_event_incident_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("incident[medication_dispensed]")
      expect(response.body).to include("incident[medications_attributes][NEW_RECORD][name]")
    end
  end
end
