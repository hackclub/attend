require "rails_helper"

RSpec.describe "Api::V1::EventVolunteers", type: :request do
  include ActiveJob::TestHelper

  let(:series) { create(:event_series, name: "Moonbeam", slug: "moonbeam-volunteers-api") }
  let(:event) { create(:event, event_series: series) }

  let(:global_admin) { User.create!(email: "ga-volunteers-api@example.com", name: "GA", global_role: "global_admin") }
  let(:series_owner) do
    User.create!(email: "owner-volunteers-api@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end

  def user_headers(user)
    { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" }
  end

  let(:event_key_headers) do
    { "Authorization" => "Bearer #{EventApiToken.generate_for(event, user: series_owner, name: 'volunteers').token}" }
  end
  let(:series_key_headers) do
    { "Authorization" => "Bearer #{SeriesApiToken.generate_for(series, user: series_owner, name: 'volunteers').token}" }
  end

  describe "GET /api/v1/events/:event_id/volunteers" do
    it "lists volunteers with their training, by slug as well as id" do
      user = User.create!(email: "listed-volunteer@example.com", name: "Pat Placeholder")
      volunteer = event.event_volunteers.create!(user: user)
      badge = create(:training_badge, name: "Safeguarding Basics", required_roles: [ "volunteer" ])

      get "/api/v1/events/#{event.slug}/volunteers", headers: user_headers(global_admin)

      expect(response).to have_http_status(:ok)
      entry = JSON.parse(response.body)["volunteers"].sole
      expect(entry).to include("id" => volunteer.id)
      expect(entry["user"]).to include("email" => "listed-volunteer@example.com", "name" => "Pat Placeholder")
      expect(entry["training"]).to eq("state" => "untrained", "missing" => [ badge.name ])
    end

    it "lets any role on the event see the roster, but not someone without one" do
      ops = create(:event_role_assignment, event: event, role: "ops").user
      outsider = User.create!(email: "outsider-volunteers-api@example.com", name: "Outsider")

      get "/api/v1/events/#{event.id}/volunteers", headers: user_headers(ops)
      expect(response).to have_http_status(:ok)

      get "/api/v1/events/#{event.id}/volunteers", headers: user_headers(outsider)
      expect(response).to have_http_status(:forbidden)
    end

    it "accepts a series API key for any event in its series, and refuses one outside it" do
      get "/api/v1/events/#{event.id}/volunteers", headers: series_key_headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/events/#{create(:event).id}/volunteers", headers: series_key_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/events/:event_id/volunteers" do
    it "adds an existing user, emails them, and audit-logs it" do
      user = User.create!(email: "new-volunteer@example.com", name: "Sam Sample")

      expect {
        post "/api/v1/events/#{event.id}/volunteers",
          params: { email: "New-Volunteer@example.com" }, headers: user_headers(global_admin)
      }.to change { event.event_volunteers.count }.by(1)
        .and have_enqueued_mail(TrainingMailer, :volunteer_added)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["account_created"]).to be(false)
      expect(body["volunteer"]["user"]).to include("id" => user.id)
      volunteer = event.event_volunteers.find_by!(user: user)
      expect(volunteer.added_by).to eq(global_admin)
      expect(AuditLog.where(action: "create", record: volunteer).count).to eq(1)
    end

    it "creates a shell account for someone who has never signed in" do
      headers = user_headers(global_admin)

      expect {
        post "/api/v1/events/#{event.id}/volunteers", params: { email: "first-volunteer@example.com" }, headers: headers
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["account_created"]).to be(true)
    end

    it "accepts an event API key for its own event, with no added_by" do
      post "/api/v1/events/#{event.id}/volunteers", params: { email: "key-volunteer@example.com" }, headers: event_key_headers

      expect(response).to have_http_status(:created)
      volunteer = event.event_volunteers.joins(:user).find_by!(users: { email: "key-volunteer@example.com" })
      expect(volunteer.added_by).to be_nil
      log = AuditLog.find_by!(action: "create", record: volunteer)
      expect(log.metadata["source"]).to eq("event_api")
      expect(log.actor).to eq(series_owner)
    end

    it "accepts a series API key for any event in its series, and refuses one outside it" do
      other_event = create(:event)

      post "/api/v1/events/#{event.slug}/volunteers", params: { email: "series-volunteer@example.com" }, headers: series_key_headers
      expect(response).to have_http_status(:created)
      log = AuditLog.find_by!(action: "create", event: event)
      expect(log.metadata).to include("source" => "series_api")

      post "/api/v1/events/#{other_event.id}/volunteers", params: { email: "series-volunteer@example.com" }, headers: series_key_headers
      expect(response).to have_http_status(:forbidden)
      expect(other_event.event_volunteers).to be_empty
    end

    it "refuses an event API key issued for a different event" do
      other_event = create(:event)

      post "/api/v1/events/#{other_event.id}/volunteers", params: { email: "nope@example.com" }, headers: event_key_headers

      expect(response).to have_http_status(:forbidden)
      expect(other_event.event_volunteers).to be_empty
    end

    it "rejects an unusable email and a duplicate" do
      headers = user_headers(global_admin)

      post "/api/v1/events/#{event.id}/volunteers", params: { email: "not-an-email" }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)

      post "/api/v1/events/#{event.id}/volunteers", params: { email: "twice@example.com" }, headers: headers
      post "/api/v1/events/#{event.id}/volunteers", params: { email: "twice@example.com" }, headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to include("already a volunteer")
      expect(event.event_volunteers.count).to eq(1)
    end
  end

  describe "DELETE /api/v1/events/:event_id/volunteers/:id" do
    it "removes the volunteer from the roster and keeps the account" do
      user = User.create!(email: "leaving-volunteer@example.com", name: "Leaving")
      volunteer = event.event_volunteers.create!(user: user)

      delete "/api/v1/events/#{event.id}/volunteers/#{volunteer.id}", headers: series_key_headers

      expect(response).to have_http_status(:no_content)
      expect(EventVolunteer.exists?(volunteer.id)).to be(false)
      expect(User.exists?(user.id)).to be(true)
      expect(AuditLog.where(action: "destroy", event: event).count).to eq(1)
    end

    it "404s for a volunteer on another event in the same series" do
      sibling = create(:event, event_series: series)
      volunteer = sibling.event_volunteers.create!(user: User.create!(email: "sibling-volunteer@example.com", name: "Sib"))

      delete "/api/v1/events/#{event.id}/volunteers/#{volunteer.id}", headers: series_key_headers

      expect(response).to have_http_status(:not_found)
      expect(EventVolunteer.exists?(volunteer.id)).to be(true)
    end
  end
end
