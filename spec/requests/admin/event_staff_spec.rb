require "rails_helper"

RSpec.describe "Admin::EventStaff", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-test@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event) }

  before do
    sign_in admin
    get select_admin_event_path(slug: event.slug)
  end

  describe "GET new" do
    it "renders the role permission breakdown for every role" do
      get new_admin_event_staff_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      EventRoleAssignment::ROLE_DETAILS.each do |_role, details|
        expect(response.body).to include(details[:summary])
        details[:can].each { |perm| expect(response.body).to include(perm) }
      end
      expect(response.body).to include('data-controller="role-info"')
    end
  end

  describe "POST create" do
    it "emails the new staff member" do
      expect {
        post admin_event_staff_index_path(event_slug: event.slug),
          params: { email: "newstaff@example.com", event_role_assignment: { role: "ops" } }
      }.to have_enqueued_mail(EventStaffMailer, :added_to_event)

      expect(response).to redirect_to(admin_event_staff_index_path(event_slug: event.slug))
    end

    it "does not email an admin who assigns themselves a role" do
      expect {
        post admin_event_staff_index_path(event_slug: event.slug),
          params: { email: admin.email, event_role_assignment: { role: "ops" } }
      }.not_to have_enqueued_mail(EventStaffMailer, :added_to_event)
    end
  end
end
