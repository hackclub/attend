require "rails_helper"

RSpec.describe "Opening an event's settings", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:selected) { create(:event, name: "Already Selected Hackathon") }
  let(:opened) { create(:event, name: "Opened Hackathon") }

  before { sign_in admin }

  { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
    it "selects that event in the sidebar #{ui}" do
      admin.update!(admin_console_beta: console)
      get admin_event_dashboard_path(selected.slug)

      get edit_admin_event_path(opened)

      expect(response).to have_http_status(:ok)
      expect(session[:current_event_id]).to eq(opened.id)
      expect(response.body).to include(admin_event_participants_path(opened))
    end
  end
end
