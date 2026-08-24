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

  describe "DELETE destroy" do
    let(:staff_user) { create(:user) }

    it "removes a regular staff member" do
      assignment = create(:event_role_assignment, event: event, user: staff_user, role: "event_admin")

      expect {
        delete admin_event_staff_path(event_slug: event.slug, id: assignment.id)
      }.to change(EventRoleAssignment, :count).by(-1)
    end

    context "when the staff member is a series owner or organizer" do
      let(:series) { create(:event_series) }
      let(:event) { create(:event, event_series: series) }

      %w[owner organizer].each do |series_role|
        it "refuses to remove a series #{series_role} whose access is inherited" do
          create(:series_role_assignment, user: staff_user, event_series: series, role: series_role)
          assignment = create(:event_role_assignment, event: event, user: staff_user, role: "event_admin")

          expect {
            delete admin_event_staff_path(event_slug: event.slug, id: assignment.id)
          }.not_to change(EventRoleAssignment, :count)

          expect(response).to redirect_to(admin_event_staff_index_path(event_slug: event.slug))
          expect(flash[:alert]).to include("inherited from the series")
        end
      end
    end
  end

  describe "GET index" do
    it "shows an inherited badge instead of a remove button for series members" do
      series = create(:event_series)
      event.update!(event_series: series)
      member = create(:user)
      create(:series_role_assignment, user: member, event_series: series, role: "owner")
      create(:event_role_assignment, event: event, user: member, role: "event_admin")

      get admin_event_staff_index_path(event_slug: event.slug)

      expect(response.body).to include("Inherited from series")
    end
  end
end
