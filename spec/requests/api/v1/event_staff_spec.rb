require "rails_helper"

RSpec.describe "Api::V1::EventStaff", type: :request do
  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-staff-api") }
  let(:event) { create(:event, event_series: series) }

  let(:global_admin) { User.create!(email: "ga-staff-api@example.com", name: "GA", global_role: "global_admin") }
  let(:series_owner) do
    User.create!(email: "owner-staff-api@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end

  def user_headers(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  let(:event_key_headers) do
    { "Authorization" => "Bearer #{EventApiToken.generate_for(event, user: series_owner, name: 'staff').token}" }
  end
  let(:series_key_headers) do
    { "Authorization" => "Bearer #{SeriesApiToken.generate_for(series, user: series_owner, name: 'staff').token}" }
  end

  describe "GET /api/v1/events/:event_id/staff" do
    it "lists assignments with the role catalogue, and takes a slug as well as an id" do
      assignment = create(:event_role_assignment, event: event, role: "safeguarding_lead")

      get "/api/v1/events/#{event.slug}/staff", headers: user_headers(global_admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["staff"].sole).to include(
        "id" => assignment.id,
        "role" => "safeguarding_lead",
        "role_label" => "Safeguarding Lead",
        "inherited_from_series" => false
      )
      expect(body["staff"].sole["user"]).to include("email" => assignment.user.email)
      expect(body["roles"].map { |role| role["role"] }).to match_array(EventRoleAssignment.roles.keys)
    end

    it "marks an assignment that only exists because of a series role" do
      create(:event_role_assignment, event: event, user: series_owner, role: "event_admin")

      get "/api/v1/events/#{event.id}/staff", headers: user_headers(global_admin)

      expect(JSON.parse(response.body)["staff"].sole).to include(
        "inherited_from_series" => true,
        "series_role" => "owner"
      )
    end

    it "refuses a staff member who isn't an event admin" do
      ops = create(:event_role_assignment, event: event, role: "ops").user

      get "/api/v1/events/#{event.id}/staff", headers: user_headers(ops)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/events/:event_id/staff" do
    it "adds an existing user, emails them, and records who did it" do
      user = User.create!(email: "newstaff@example.com", name: "New Staff")

      expect {
        post "/api/v1/events/#{event.id}/staff",
          params: { email: "NewStaff@example.com", role: "ops" },
          headers: user_headers(global_admin)
      }.to change { event.event_role_assignments.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["staff_member"]).to include("role" => "ops")
      expect(body["account_created"]).to be(false)
      expect(event.event_role_assignments.find_by(user: user)).to be_present
      expect(AuditLog.where(action: "add_team_member", event: event).count).to eq(1)
    end

    it "creates a shell account for someone who has never signed in" do
      headers = user_headers(global_admin)

      expect {
        post "/api/v1/events/#{event.id}/staff",
          params: { email: "firsttimer@example.com", role: "event_admin" },
          headers: headers
      }.to change(User, :count).by(1)

      expect(JSON.parse(response.body)["account_created"]).to be(true)
      expect(User.find_by(email: "firsttimer@example.com").name).to eq("Firsttimer")
    end

    it "accepts an event API key for its own event" do
      post "/api/v1/events/#{event.id}/staff",
        params: { email: "keyadded@example.com", role: "ops" },
        headers: event_key_headers

      expect(response).to have_http_status(:created)
      assignment = event.event_role_assignments.joins(:user).find_by(users: { email: "keyadded@example.com" })
      expect(assignment.role).to eq("ops")
      log = AuditLog.find_by(action: "add_team_member", event: event)
      expect(log.metadata["source"]).to eq("event_api")
      expect(log.actor).to eq(series_owner)
    end

    it "accepts a series API key for any event in its series, and refuses one outside it" do
      other_event = create(:event)

      post "/api/v1/events/#{event.id}/staff",
        params: { email: "series-added@example.com", role: "limited" }, headers: series_key_headers
      expect(response).to have_http_status(:created)

      post "/api/v1/events/#{other_event.id}/staff",
        params: { email: "series-added@example.com", role: "limited" }, headers: series_key_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses an event API key issued for a different event" do
      other_event = create(:event)

      post "/api/v1/events/#{other_event.id}/staff",
        params: { email: "nope@example.com", role: "ops" }, headers: event_key_headers

      expect(response).to have_http_status(:forbidden)
      expect(other_event.event_role_assignments).to be_empty
    end

    it "rejects an unknown role and an unusable email" do
      post "/api/v1/events/#{event.id}/staff",
        params: { email: "who@example.com", role: "supreme_leader" }, headers: user_headers(global_admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("event_admin")

      post "/api/v1/events/#{event.id}/staff",
        params: { email: "not-an-email", role: "ops" }, headers: user_headers(global_admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(event.event_role_assignments).to be_empty
    end

    it "rejects a second assignment for someone who already has that role" do
      assignment = create(:event_role_assignment, event: event, role: "ops")

      post "/api/v1/events/#{event.id}/staff",
        params: { email: assignment.user.email, role: "ops" }, headers: user_headers(global_admin)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/events/:event_id/staff/:id" do
    it "changes the role" do
      assignment = create(:event_role_assignment, event: event, role: "read_only")

      patch "/api/v1/events/#{event.id}/staff/#{assignment.id}",
        params: { role: "ops" }, headers: user_headers(global_admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["staff_member"]["role"]).to eq("ops")
      expect(assignment.reload.role).to eq("ops")
    end

    it "404s for an assignment on another event" do
      assignment = create(:event_role_assignment, role: "ops")

      patch "/api/v1/events/#{event.id}/staff/#{assignment.id}",
        params: { role: "ops" }, headers: user_headers(global_admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/events/:event_id/staff/:id" do
    it "removes the assignment" do
      assignment = create(:event_role_assignment, event: event, role: "ops")

      delete "/api/v1/events/#{event.id}/staff/#{assignment.id}", headers: user_headers(global_admin)

      expect(response).to have_http_status(:no_content)
      expect(EventRoleAssignment.exists?(assignment.id)).to be(false)
      expect(AuditLog.where(action: "remove_team_member").count).to eq(1)
    end

    it "refuses to remove access that is inherited from the series" do
      assignment = create(:event_role_assignment, event: event, user: series_owner, role: "event_admin")

      delete "/api/v1/events/#{event.id}/staff/#{assignment.id}", headers: user_headers(global_admin)

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to include("series members page")
      expect(EventRoleAssignment.exists?(assignment.id)).to be(true)
    end
  end
end
