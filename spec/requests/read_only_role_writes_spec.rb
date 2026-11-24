require "rails_helper"

# read_only is "view-only access — cannot make changes". Getting into /admin
# takes an admin role on *some* event, and the mobile API takes any role at
# all, so neither front door keeps a read_only assignment read-only by itself.
RSpec.describe "Read-only event role", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event, status: :complete) }
  let(:user) { create(:user) }

  before { create(:event_role_assignment, user: user, event: event, role: "read_only") }

  describe "on the web, for someone who is ops on another event" do
    before do
      create(:event_role_assignment, user: user, event: create(:event), role: "ops")
      sign_in user
    end

    it "can open the event" do
      get admin_event_scan_contexts_path(event)

      expect(response).to have_http_status(:ok)
    end

    it "cannot record a scan" do
      context = event.scan_contexts.find_by!(checks_in: true)

      expect {
        post "/admin/events/#{event.slug}/scans", params: { participant_id: participant_event.id, scan_context_id: context.id }
      }.not_to change(Scan, :count)
    end

    it "cannot create a scan context" do
      expect {
        post "/admin/events/#{event.slug}/scan_contexts", params: { scan_context: { name: "Side door", kind: "tracking_only" } }
      }.not_to change(ScanContext, :count)
    end

    it "cannot edit the event" do
      expect {
        patch "/admin/events/#{event.slug}", params: { event: { name: "Renamed" } }
      }.not_to change { event.reload.name }
    end

    it "cannot draft a broadcast" do
      expect {
        post "/admin/events/#{event.slug}/messages",
          params: { message: { subject: "Hi", body: "Hello", audience: "all", channels: [ "email" ] } }
      }.not_to change(Message, :count)
    end

    it "cannot send a Slack blast" do
      participant_event.participant.update!(slack_user_id: "U0EXAMPLE")

      expect {
        post "/admin/events/#{event.slug}/slack_blasts", params: { message: "Doors open" }
      }.not_to change(SlackBlast, :count)
    end

    it "still works the event they are ops on" do
      other = user.event_role_assignments.find_by!(role: "ops").event

      expect {
        post "/admin/events/#{other.slug}/scan_contexts", params: { scan_context: { name: "Side door", kind: "tracking_only" } }
      }.to change(other.scan_contexts, :count).by(1)
    end
  end

  describe "on the API" do
    let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" } }
    let(:message_params) { { message: { subject: "Hi", body: "Hello", audience: "all", channels: [ "email" ] } } }

    it "can read broadcasts but not draft one" do
      get "/api/v1/events/#{event.id}/messages", headers: headers
      expect(response).to have_http_status(:ok)

      expect {
        post "/api/v1/events/#{event.id}/messages", params: message_params, headers: headers, as: :json
      }.not_to change(Message, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot send a broadcast someone else drafted" do
      author = create(:user, global_role: "global_admin")
      post "/api/v1/events/#{event.id}/messages", params: message_params,
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(author).token}" }, as: :json
      message = event.messages.sole

      expect {
        post "/api/v1/events/#{event.id}/messages/#{message.id}/send_now", headers: headers, as: :json
      }.not_to change { message.reload.status }
      expect(response).to have_http_status(:forbidden)
    end

    it "can read setup but not complete it" do
      get "/api/v1/events/#{event.id}/setup", headers: headers
      expect(response).to have_http_status(:ok)

      event.update!(setup_completed_at: nil)
      post "/api/v1/events/#{event.id}/setup/complete", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(event.reload.setup_completed_at).to be_nil
    end

    it "can list volunteers but not add one" do
      get "/api/v1/events/#{event.id}/volunteers", headers: headers
      expect(response).to have_http_status(:ok)

      expect {
        post "/api/v1/events/#{event.id}/volunteers", params: { email: "volunteer@example.com", name: "Sam Example" }, headers: headers, as: :json
      }.not_to change(EventVolunteer, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
