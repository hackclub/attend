require "rails_helper"

RSpec.describe "Docs", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-docs@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:event_admin) do
    User.create!(email: "ea-docs@example.com", name: "Event Admin").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end
  let(:regular_user) { User.create!(email: "user-docs@example.com", name: "Regular User") }

  describe "GET /docs" do
    it "redirects an unauthenticated visitor" do
      get docs_path
      expect(response).to have_http_status(:redirect)
    end

    it "redirects a non-admin user" do
      sign_in regular_user
      get docs_path
      expect(response).to redirect_to(root_path)
    end

    it "renders the Scalar reference for a global admin" do
      sign_in global_admin
      get docs_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("api-reference")
      expect(response.body).to include(docs_openapi_path(format: :json))
    end

    it "renders for an event admin" do
      sign_in event_admin
      get docs_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /docs/openapi.json" do
    it "does not serve the spec to a non-admin" do
      sign_in regular_user
      get docs_openapi_path(format: :json)
      expect(response).to redirect_to(root_path)
    end

    it "serves a valid OpenAPI document to an admin" do
      sign_in global_admin
      get docs_openapi_path(format: :json)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      doc = JSON.parse(response.body)
      expect(doc["openapi"]).to start_with("3.")
      expect(doc.dig("info", "title")).to eq("Attend API")
      expect(doc["paths"]).to include("/me", "/events/{event_id}/participants")
    end

    it "documents the UUID travel paths and nullable group-object entry contract" do
      sign_in global_admin
      get docs_openapi_path(format: :json)

      doc = JSON.parse(response.body)
      canonical = doc.dig("paths", "/events/{event_id}/travel", "get")
      legacy = doc.dig("paths", "/events/{event_id}/airport_mode", "get")
      entry = doc.dig("components", "schemas", "TravelCalendarEntry", "properties")

      expect(canonical.fetch("parameters").sole).to eq("$ref" => "#/components/parameters/EventIdUuid")
      expect(legacy.fetch("parameters").sole).to eq("$ref" => "#/components/parameters/EventIdUuid")
      expect(legacy["deprecated"]).to be(true)
      expect(doc.dig("components", "parameters", "EventIdUuid", "schema")).to eq(
        "type" => "string",
        "format" => "uuid"
      )
      expect(entry.values_at("participantPreferredName", "mode", "route")).to all(include("nullable" => true))
      expect(entry.dig("groups", "items")).to eq(
        "type" => "object",
        "required" => %w[id name color],
        "properties" => {
          "id" => { "type" => "string", "format" => "uuid" },
          "name" => { "type" => "string" },
          "color" => { "type" => "string", "nullable" => true }
        }
      )
    end
  end
end
