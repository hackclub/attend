require "rails_helper"

# The invited person's side: the emailed link, accepting, and creating the one
# event the invite allows.
RSpec.describe "Event creation invite flow", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:inviter) { create(:user, name: "The Boss", global_role: "global_admin") }
  let(:invitee) { create(:user, email: "organizer@example.com") }
  let(:invite) { create(:event_creation_invite, email: "organizer@example.com", invited_by: inviter) }
  let(:token) { invite.issue_token! }
  let(:event_params) { { name: "Invited Con", slug: "invited-con", support_email: "invited@hackclub.com" } }

  describe "the link" do
    it "asks a signed-out visitor to sign in, and brings them back afterwards" do
      get event_creation_invite_path(token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("The Boss", "Continue with Hack Club", "organizer@example.com")
      expect(session["user_return_to"]).to eq(event_creation_invite_path(token))
    end

    it "walks the invited account through what setup covers, in the admin console" do
      invitee.update!(admin_console_beta: false)
      sign_in invitee

      get event_creation_invite_path(token)
      expect(response).to redirect_to(admin_event_creation_invite_welcome_path(token))

      follow_redirect!
      expect(response.body).to include("What setup covers", "Get started", "cs-wizard")
    end

    it "takes them straight to their event once it exists" do
      sign_in invitee
      invite.accept!(invitee)
      event = create(:event, :draft)
      invite.complete!(event)

      get event_creation_invite_path(token)

      expect(response).to redirect_to(admin_event_setup_path(event))
    end

    it "turns away an account with a different address" do
      sign_in create(:user, email: "someone-else@example.com")

      get event_creation_invite_path(token)
      expect(response.body).to include("This invite is for a different account")

      get admin_event_creation_invite_welcome_path(token)
      expect(response).to redirect_to(event_creation_invite_path(token))

      post admin_accept_event_creation_invite_path(token)
      expect(invite.reload).to be_pending
    end

    it "says so when the invite has expired, been revoked, or the link is wrong" do
      invite.update!(expires_at: 1.day.ago)
      get event_creation_invite_path(token)
      expect(response.body).to include("This invite has expired")

      invite.update!(expires_at: 1.day.from_now, revoked_at: Time.current)
      get event_creation_invite_path(token)
      expect(response.body).to include("This invite was withdrawn")

      get event_creation_invite_path("not-a-token")
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "accepting and creating the event" do
    before { sign_in invitee }

    it "lets someone with no admin access create one event and become its admin" do
      post admin_accept_event_creation_invite_path(token)
      expect(response).to redirect_to(admin_new_event_path(invite: invite.id))

      get admin_new_event_path(invite: invite.id)
      expect(response).to have_http_status(:ok)

      post admin_events_path, params: { invite: invite.id, event: event_params }

      event = Event.find_by!(slug: "invited-con")
      expect(response).to redirect_to(admin_event_setup_schedule_path(event))
      expect(invite.reload).to have_attributes(status: "completed", event: event)
      expect(invitee.event_admin_for?(event)).to be(true)

      get admin_event_setup_schedule_path(event)
      expect(response).to have_http_status(:ok)

      # The invite is spent: no second event.
      post admin_events_path, params: { invite: invite.id, event: event_params.merge(name: "Second Con", slug: "second-con") }
      expect(Event.find_by(slug: "second-con")).to be_nil
    end

    it "puts the event in the invite's series, whatever the form says" do
      series = create(:event_series)
      other_series = create(:event_series)
      invite.update!(event_series: series)
      post admin_accept_event_creation_invite_path(token)

      post admin_events_path, params: { invite: invite.id, event: event_params.merge(event_series_id: other_series.id) }

      expect(Event.find_by!(slug: "invited-con").event_series).to eq(series)
      expect(invitee.series_role_assignments).to be_empty
    end

    it "sends the rest of the admin back to the new event form until the event exists" do
      post admin_accept_event_creation_invite_path(token)

      get admin_root_path

      expect(response).to redirect_to(admin_new_event_path(invite: invite.id))
    end

    it "stops working once revoked" do
      post admin_accept_event_creation_invite_path(token)
      invite.revoke!

      post admin_events_path, params: { invite: invite.id, event: event_params }

      expect(Event.find_by(slug: "invited-con")).to be_nil
      expect(response).to redirect_to(root_path)
    end

    it "doesn't open event creation before the invite is accepted" do
      token

      get admin_new_event_path
      expect(response).to redirect_to(root_path)

      post admin_events_path, params: { invite: invite.id, event: event_params }
      expect(Event.find_by(slug: "invited-con")).to be_nil
    end
  end
end
