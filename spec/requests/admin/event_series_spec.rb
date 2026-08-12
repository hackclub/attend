require "rails_helper"

RSpec.describe "Admin::EventSeries", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-spec") }
  let!(:sub_event) { create(:event, event_series: series) }
  let(:other_event) { create(:event) }

  let(:global_admin) { User.create!(email: "ga-series@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:owner) do
    User.create!(email: "owner-series@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:organizer) do
    User.create!(email: "organizer-series@example.com", name: "Organizer").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "organizer")
    end
  end
  let(:unrelated_event_admin) do
    User.create!(email: "ea-series@example.com", name: "Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: other_event, role: "event_admin")
    end
  end

  describe "series pages" do
    it "lets a series member view the series and its events" do
      sign_in organizer

      get admin_series_index_path
      expect(response).to have_http_status(:ok)

      get admin_series_path(series)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(sub_event.name)
    end

    it "blocks users with no series membership" do
      sign_in unrelated_event_admin

      get admin_series_path(series)
      expect(response).to redirect_to(root_path)
    end

    it "blocks organizers from series settings" do
      sign_in organizer

      get edit_admin_series_path(series)
      expect(response).to redirect_to(root_path)
    end

    it "lets owners update the series" do
      sign_in owner

      patch admin_series_path(series), params: { event_series: { name: "Sunbeam Renamed" } }

      expect(series.reload.name).to eq("Sunbeam Renamed")
    end

    it "only lets global admins create a series" do
      sign_in owner
      post admin_series_index_path, params: { event_series: { name: "Another Series" } }
      expect(EventSeries.find_by(name: "Another Series")).to be_nil

      sign_in global_admin
      post admin_series_index_path, params: { event_series: { name: "Another Series" } }
      expect(EventSeries.find_by(name: "Another Series")).to be_present
    end
  end

  describe "member management" do
    it "lets owners add and remove members" do
      sign_in owner

      post admin_series_members_path(series), params: {
        email: "new-member@example.com",
        series_role_assignment: { role: "organizer" }
      }

      assignment = series.series_role_assignments.joins(:user).find_by(users: { email: "new-member@example.com" })
      expect(assignment).to be_present
      expect(assignment.role).to eq("organizer")

      delete admin_series_member_path(series, assignment)
      expect(series.series_role_assignments.exists?(assignment.id)).to be(false)
    end

    it "blocks organizers from member management" do
      sign_in organizer

      get admin_series_members_path(series)
      expect(response).to redirect_to(admin_series_path(series))
    end
  end

  describe "event access via series membership" do
    it "grants members admin access to every event in the series" do
      sign_in organizer

      get admin_event_dashboard_path(sub_event.slug)
      expect(response).to have_http_status(:ok)
    end

    it "does not grant access to events outside the series" do
      sign_in organizer

      get admin_event_dashboard_path(other_event.slug)
      expect(response).to redirect_to(root_path)
    end

    it "scopes the events list to series events plus assigned events" do
      resolved = EventPolicy::Scope.new(organizer, Event).resolve
      expect(resolved).to include(sub_event)
      expect(resolved).not_to include(other_event)
    end
  end

  describe "event creation by series members" do
    it "lets a member create an event inside their series and makes them event admin" do
      sign_in organizer

      post admin_events_path, params: {
        event: { name: "Sunbeam Berlin Spec", event_series_id: series.id }
      }

      event = Event.find_by(name: "Sunbeam Berlin Spec")
      expect(event).to be_present
      expect(event.event_series).to eq(series)
      expect(event.event_role_assignments.find_by(user: organizer)&.role).to eq("event_admin")
    end

    it "blocks creating an event with no series" do
      sign_in organizer

      post admin_events_path, params: { event: { name: "Standalone Spec" } }

      expect(Event.find_by(name: "Standalone Spec")).to be_nil
    end

    it "blocks creating an event in a series the user is not a member of" do
      foreign_series = create(:event_series)
      sign_in organizer

      post admin_events_path, params: {
        event: { name: "Foreign Spec", event_series_id: foreign_series.id }
      }

      expect(Event.find_by(name: "Foreign Spec")).to be_nil
    end

    it "does not let members move an event between series on update" do
      foreign_series = create(:event_series)
      sign_in organizer

      patch admin_event_path(sub_event), params: {
        event: { name: sub_event.name, event_series_id: foreign_series.id }
      }

      expect(sub_event.reload.event_series).to eq(series)
    end
  end

  describe "linking existing events (global admin)" do
    it "lets a global admin move an existing event into a series" do
      sign_in global_admin

      patch admin_event_path(other_event), params: {
        event: { name: other_event.name, event_series_id: series.id }
      }

      expect(other_event.reload.event_series).to eq(series)
    end
  end
end
