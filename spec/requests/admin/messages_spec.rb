require "rails_helper"

RSpec.describe "Admin::Messages", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-test@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event) }

  before { sign_in admin }

  describe "GET new" do
    it "renders the compose form without creating a draft" do
      expect {
        get new_admin_event_message_path(event_slug: event.slug)
      }.not_to change(Message, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Compose Message")
    end
  end

  describe "POST create" do
    let(:params) do
      { message: { audience: "confirmed_attendees", channels: [ "slack" ], subject: "Hi", body: "<p>Hello</p>" } }
    end

    it "creates a draft owned by the current user and redirects to preview" do
      expect {
        post admin_event_messages_path(event_slug: event.slug), params: params
      }.to change(Message, :count).by(1)

      message = Message.last
      expect(message.status).to eq("draft")
      expect(message.sent_by_user).to eq(admin)
      expect(message.body).to eq("<p>Hello</p>")
      expect(response).to redirect_to(preview_admin_event_message_path(event_slug: event.slug, id: message))
    end

    it "responds with JSON for autosave including the update url" do
      post admin_event_messages_path(event_slug: event.slug, format: :json), params: params

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["update_url"]).to be_present
      expect(body["edit_url"]).to be_present
    end
  end
end
