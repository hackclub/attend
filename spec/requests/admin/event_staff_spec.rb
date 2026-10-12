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

  describe "PATCH update" do
    let(:staff_user) { create(:user) }
    let!(:assignment) { create(:event_role_assignment, event: event, user: staff_user, role: "ops") }
    let(:turbo_stream) { { "Accept" => "text/vnd.turbo-stream.html, text/html" } }

    def change_role(role, headers: {})
      patch admin_event_staff_path(event_slug: event.slug, id: assignment.id),
        params: { event_role_assignment: { role: role } }, headers: headers
    end

    it "changes the role and redirects back to the staff list" do
      change_role("limited")

      expect(assignment.reload.role).to eq("limited")
      expect(response).to redirect_to(admin_event_staff_index_path(event_slug: event.slug))
      expect(flash[:notice]).to include("is now Limited")
    end

    it "audit-logs the role change" do
      expect { change_role("read_only") }.to change(AuditLog, :count).by(1)
      expect(AuditLog.last.changed_fields).to include("role" => [ "ops", "read_only" ])
    end

    it "answers an inline edit with the role cell, showing the success icon" do
      change_role("safeguarding_lead", headers: turbo_stream)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(%(target="role_cell_event_role_assignment_#{assignment.id}"))
      expect(response.body).to include("cs-inline-edit-saved")
      expect(response.body).to include("Role changed to Safeguarding Lead.")
      expect(assignment.reload.role).to eq("safeguarding_lead")
    end

    it "rejects a role that doesn't exist, keeping the cell in edit mode" do
      change_role("superuser", headers: turbo_stream)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Choose one of the listed roles.")
      expect(response.body).to include('aria-invalid="true"')
      expect(assignment.reload.role).to eq("ops")
    end

    it "explains when the person already holds that role through another row" do
      create(:event_role_assignment, event: event, user: staff_user, role: "limited")

      change_role("limited", headers: turbo_stream)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("already has the Limited role on this event.")
      expect(assignment.reload.role).to eq("ops")
    end

    context "when the staff member is a series owner" do
      let(:series) { create(:event_series) }
      let(:event) { create(:event, event_series: series) }

      it "refuses, since their access comes from the series" do
        create(:series_role_assignment, user: staff_user, event_series: series, role: "owner")

        change_role("read_only")

        expect(assignment.reload.role).to eq("ops")
        expect(flash[:alert]).to include("series members page")
      end
    end

    context "when an event admin edits their own row" do
      let(:event_admin) { create(:user) }
      let!(:own_assignment) { create(:event_role_assignment, event: event, user: event_admin, role: "event_admin") }

      before do
        sign_in event_admin
        get select_admin_event_path(slug: event.slug)
      end

      it "refuses, so they can't lock themselves out of staff management" do
        patch admin_event_staff_path(event_slug: event.slug, id: own_assignment.id),
          params: { event_role_assignment: { role: "read_only" } }

        expect(own_assignment.reload.role).to eq("event_admin")
        expect(flash[:alert]).to include("can't change your own role")
      end

      it "still lets them change someone else's role" do
        change_role("limited")

        expect(assignment.reload.role).to eq("limited")
      end
    end

    it "is closed to staff who aren't event admins" do
      sign_in staff_user
      change_role("event_admin")

      expect(assignment.reload.role).to eq("ops")
    end
  end

  describe "GET index with the admin console beta" do
    let(:staff_user) { create(:user) }

    before { admin.update!(admin_console_beta: true) }

    it "renders an inline-editable role cell" do
      assignment = create(:event_role_assignment, event: event, user: staff_user, role: "ops")

      get admin_event_staff_index_path(event_slug: event.slug)

      cell = Nokogiri::HTML(response.body).at_css("#role_cell_event_role_assignment_#{assignment.id}")
      expect(cell["data-controller"]).to eq("cs-inline-edit")
      expect(cell.at_css("button.cs-inline-edit-trigger")["aria-label"]).to start_with("Edit role for")
      expect(cell.at_css("form")["hidden"]).not_to be_nil
      expect(cell.css("select option").map { |o| o["value"] }).to eq(EventRoleAssignment::ROLE_DETAILS.keys)
    end

    it "locks the role cell for a series member and says why" do
      series = create(:event_series)
      event.update!(event_series: series)
      create(:series_role_assignment, user: staff_user, event_series: series, role: "organizer")
      assignment = create(:event_role_assignment, event: event, user: staff_user, role: "event_admin")

      get admin_event_staff_index_path(event_slug: event.slug)

      cell = Nokogiri::HTML(response.body).at_css("#role_cell_event_role_assignment_#{assignment.id}")
      expect(cell.at_css("form")).to be_nil
      expect(cell.at_css("button.cs-inline-edit-trigger")["aria-disabled"]).to eq("true")
      expect(cell.at_css(".cs-inline-edit-reason").text).to include("series members page")
    end
  end
end
