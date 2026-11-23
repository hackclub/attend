require "rails_helper"

RSpec.describe "Admin::EventCreationInvites", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  [ true, false ].each do |console|
    context "with the #{console ? 'console' : 'original'} admin" do
      let(:global_admin) { User.create!(email: "ga-invites@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: console) }

      before { sign_in global_admin }

      it "lists invites with where each one has got to" do
        create(:event_creation_invite, email: "waiting@example.com")
        done = create(:event_creation_invite, :accepted, email: "done@example.com")
        done.complete!(create(:event, name: "Made Con"))

        get admin_event_creation_invites_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("waiting@example.com", "Sent", "done@example.com", "Event created", "Made Con")
      end

      it "creates an invite and emails it" do
        series = create(:event_series)

        expect {
          post admin_event_creation_invites_path, params: {
            event_creation_invite: { email: "New.Organizer@example.com", event_series_id: series.id, note: "Welcome!" }
          }
        }.to have_enqueued_mail(EventCreationInviteMailer, :invite)

        invite = EventCreationInvite.last
        expect(invite).to have_attributes(email: "new.organizer@example.com", event_series: series, invited_by: global_admin, note: "Welcome!")
        expect(response).to redirect_to(admin_event_creation_invites_path)
      end

      it "shows why an invite couldn't be created" do
        create(:event_creation_invite, email: "taken@example.com")

        get new_admin_event_creation_invite_path
        expect(response).to have_http_status(:ok)

        post admin_event_creation_invites_path, params: { event_creation_invite: { email: "taken@example.com" } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("already has an open invite")
      end

      it "resends with a fresh link and a full window" do
        invite = create(:event_creation_invite, :expired)
        old_token = invite.issue_token!

        perform_enqueued_jobs { post resend_admin_event_creation_invite_path(invite) }

        expect(invite.reload).to be_pending
        expect(EventCreationInvite.find_by_token(old_token)).to be_nil
        expect(ActionMailer::Base.deliveries.last.to).to eq([ invite.email ])
      end

      it "revokes an invite, but not one that already made an event" do
        invite = create(:event_creation_invite)
        patch revoke_admin_event_creation_invite_path(invite)
        expect(invite.reload).to be_revoked

        used = create(:event_creation_invite, :accepted)
        used.complete!(create(:event))
        patch revoke_admin_event_creation_invite_path(used)
        expect(used.reload).to be_completed
      end
    end
  end

  it "is for global admins only" do
    event_admin = create(:user)
    create(:event).event_role_assignments.create!(user: event_admin, role: "event_admin")
    sign_in event_admin

    get admin_event_creation_invites_path
    expect(response).to redirect_to(admin_root_path)

    expect {
      post admin_event_creation_invites_path, params: { event_creation_invite: { email: "someone@example.com" } }
    }.not_to change(EventCreationInvite, :count)
  end
end
