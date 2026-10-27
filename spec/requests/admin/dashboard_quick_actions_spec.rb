require "rails_helper"

# The console dashboard's quick-actions grid: the old admin's row of coloured
# icon tiles, gated the same way as the side navigation so no tile dead-ends.
RSpec.describe "Admin dashboard quick actions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, travel_enabled: true, accommodation_enabled: true) }

  def visit_dashboard(user)
    sign_in user
    get select_admin_event_path(slug: event.slug)
    get admin_event_dashboard_path(event.slug)
  end

  context "with the admin console beta" do
    let(:admin) { create(:user, global_role: "global_admin", admin_console_beta: true) }

    it "lists every event surface as a tinted tile" do
      visit_dashboard(admin)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-testid="quick-actions"')
      {
        admin_event_scans_path(event) => "cs-tint-red",
        admin_event_participants_path(event) => "cs-tint-indigo",
        admin_event_travel_path(event) => "cs-tint-sky",
        admin_event_rooming_wizard_path(event) => "cs-tint-teal",
        admin_event_incidents_path(event) => "cs-tint-amber",
        admin_event_messages_path(event) => "cs-tint-purple",
        admin_event_exports_path(event) => "cs-tint-green",
        admin_audit_logs_path(event_id: event.id) => "cs-tint-grey"
      }.each do |path, tint|
        expect(response.body).to match(/class="cs-quick-action" href="#{Regexp.escape(ERB::Util.html_escape(path))}">\s*<span class="cs-quick-action-icon #{tint}">/)
      end
    end

    it "hides travel and rooming tiles when those modules are off" do
      event.update!(travel_enabled: false, accommodation_enabled: false)
      visit_dashboard(admin)

      quick_actions = response.body[/data-testid="quick-actions".*?<\/section>/m]
      expect(quick_actions).not_to include(admin_event_travel_path(event))
      expect(quick_actions).not_to include(admin_event_rooming_wizard_path(event))
      expect(quick_actions).to include(admin_event_scans_path(event))
    end

    it "keeps the audit log tile from staff who can't open audit logs" do
      ops = create(:user, admin_console_beta: true)
      create(:event_role_assignment, user: ops, event: event, role: :ops)
      visit_dashboard(ops)

      quick_actions = response.body[/data-testid="quick-actions".*?<\/section>/m]
      expect(quick_actions).to include(admin_event_scans_path(event))
      expect(quick_actions).not_to include(admin_audit_logs_path(event_id: event.id))
    end
  end

  it "leaves the original dashboard untouched" do
    visit_dashboard(create(:user, global_role: "global_admin", admin_console_beta: false))

    expect(response.body).not_to include('data-testid="quick-actions"')
    expect(response.body).to include("Quick Actions")
  end
end
