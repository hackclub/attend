require "rails_helper"

RSpec.describe "Admin::SeriesApiTokens", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-tokens") }
  let(:other_series) { create(:event_series, slug: "moonbeam-tokens") }

  let(:owner) do
    User.create!(email: "owner-tokens@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:organizer) do
    User.create!(email: "organizer-tokens@example.com", name: "Organizer").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "organizer")
    end
  end
  let(:global_admin) do
    User.create!(email: "ga-tokens@example.com", name: "Global Admin", global_role: "global_admin")
  end

  describe "issuing a key" do
    it "shows the secret exactly once and never again" do
      sign_in owner

      post admin_series_api_tokens_path(series), params: { name: "series-ops" }
      raw_secret = flash[:series_api_token]
      follow_redirect!

      expect(SeriesApiToken.last.name).to eq("owner-tokens@series-ops")
      expect(raw_secret).to start_with("attn_")
      expect(response.body).to include(raw_secret)

      # Reloading the page has nothing left to show — only the digest is stored.
      get admin_series_api_tokens_path(series)
      expect(response.body).to include("owner-tokens@series-ops")
      expect(response.body).not_to include(raw_secret)
    end

    it "rejects a blank name" do
      sign_in owner

      expect {
        post admin_series_api_tokens_path(series), params: { name: "  " }
      }.not_to change(SeriesApiToken, :count)

      expect(flash[:alert]).to match(/enter a name/)
    end
  end

  describe "rotating and revoking" do
    let!(:token) { SeriesApiToken.generate_for(series, user: owner, name: "series-ops") }

    it "rotates in place, keeping the row and its name" do
      sign_in owner
      original_digest = token.token_digest

      post rotate_admin_series_api_token_path(series, token)

      expect(token.reload.token_digest).not_to eq(original_digest)
      expect(token.name).to eq("owner-tokens@series-ops")
    end

    it "revokes without deleting the row, so the audit trail survives" do
      sign_in owner

      delete admin_series_api_token_path(series, token)

      expect(token.reload).to be_revoked
      expect(SeriesApiToken.active).not_to include(token)
    end

    it "will not touch a key belonging to another series" do
      elsewhere = SeriesApiToken.generate_for(other_series, user: global_admin, name: "theirs")
      sign_in owner

      delete admin_series_api_token_path(series, elsewhere)

      # ApplicationController turns the missing scoped lookup into a redirect.
      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to match(/could not be found/)
      expect(elsewhere.reload).not_to be_revoked
    end
  end

  describe "who may manage keys" do
    it "lets a series owner in" do
      sign_in owner

      get admin_series_api_tokens_path(series)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("API Keys")
    end

    it "lets a global admin in" do
      sign_in global_admin

      get admin_series_api_tokens_path(series)

      expect(response).to have_http_status(:ok)
    end

    # An organizer can already create events through the web; a key that also
    # works unattended is an owner-level grant, same bar as adding a member.
    it "turns a series organizer away" do
      sign_in organizer

      get admin_series_api_tokens_path(series)

      expect(response).to redirect_to(admin_series_path(series))
      expect(flash[:alert]).to match(/Only series owners/)
    end

    it "turns away an event admin from another series" do
      elsewhere_admin = User.create!(email: "outsider-tokens@example.com", name: "Outsider")
      EventRoleAssignment.create!(user: elsewhere_admin, event: create(:event, event_series: other_series), role: "event_admin")
      sign_in elsewhere_admin

      get admin_series_api_tokens_path(series)

      expect(response).to have_http_status(:redirect)
      expect(SeriesApiToken.count).to eq(0)
    end
  end

  it "audit-logs every write, since a key is a standing grant" do
    sign_in owner

    expect {
      post admin_series_api_tokens_path(series), params: { name: "series-ops" }
    }.to change(AuditLog, :count).by(1)

    expect(AuditLog.order(:created_at).last.action).to eq("record_create")
  end
end
