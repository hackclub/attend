require "rails_helper"

# Only event admins (and series owners/organizers, who act as event admins)
# may add people to an event. Every other role's ROLE_DETAILS say "cannot add
# or remove participants", and an event API token can invite without any role
# check, so minting tokens is gated the same way. See issue #129.
RSpec.describe "Participant invite permissions", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:series) { create(:event_series) }
  let(:event) { create(:event, event_series: series) }

  def sign_in_with_role(role)
    user = User.create!(email: "#{role}-invite-spec@example.com", name: role.titleize)
    EventRoleAssignment.create!(user: user, event: event, role: role)
    sign_in user
    user
  end

  def sign_in_series_organizer
    user = User.create!(email: "organizer-invite-spec@example.com", name: "Organizer")
    SeriesRoleAssignment.create!(user: user, event_series: series, role: "organizer")
    sign_in user
    user
  end

  def csv_upload
    Rack::Test::UploadedFile.new(
      StringIO.new("Email,Legal First Name,Legal Last Name\nnew@example.com,New,Person\n"),
      "text/csv", original_filename: "participants.csv"
    )
  end

  # read_only is absent: User#admin? keeps that role out of the admin area
  # altogether, so it never reaches these actions.
  %w[limited ops safeguarding_lead].each do |role|
    context "as #{role}" do
      before { sign_in_with_role(role) }

      it "cannot open the invite form" do
        get new_invite_admin_event_participants_path(event.slug)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq("You are not authorized to perform this action.")
      end

      it "cannot send an invitation" do
        expect {
          post send_invite_admin_event_participants_path(event.slug),
            params: { invite: { email: "sneaky@example.com" } }
        }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

        expect(response).to redirect_to(root_path)
      end

      it "cannot revoke an invitation" do
        invitation = create(:invitation, event: event)

        delete revoke_invite_admin_event_participants_path(event.slug, id: invitation.id)

        expect(response).to redirect_to(root_path)
        expect(Invitation.exists?(invitation.id)).to be(true)
      end

      it "cannot open the CSV import" do
        get new_admin_event_import_path(event.slug)

        expect(response).to redirect_to(root_path)
      end

      it "cannot start a CSV import" do
        expect {
          post admin_event_imports_path(event.slug), params: { csv_file: csv_upload }
        }.not_to change(ImportBatch, :count)

        expect(response).to redirect_to(root_path)
      end

      it "cannot create an event API token" do
        expect {
          post admin_event_api_tokens_path(event.slug), params: { name: "backdoor" }
        }.not_to change(EventApiToken, :count)

        expect(response).to redirect_to(root_path)
      end

      it "cannot rotate or revoke an event API token" do
        token = EventApiToken.generate_for(event, user: create(:user), name: "existing")
        digest = token.token_digest

        post admin_rotate_event_api_token_path(event.slug, token.id)
        expect(response).to redirect_to(root_path)
        expect(token.reload.token_digest).to eq(digest)

        delete admin_event_api_token_path(event.slug, token.id)
        expect(response).to redirect_to(root_path)
        expect(token.reload).to be_active
      end

      it "cannot regenerate the legacy API key" do
        post regenerate_api_key_admin_event_path(event.slug)

        expect(response).to redirect_to(root_path)
        expect(event.reload.api_key_set?).to be(false)
      end

      it "sees no invite, import, or token controls" do
        create(:invitation, event: event)

        get admin_event_participants_path(event.slug)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(new_invite_admin_event_participants_path(event.slug))
        expect(response.body).not_to include(new_admin_event_import_path(event.slug))

        get admin_event_participants_path(event.slug, status: "pending_invitations")
        expect(response.body).not_to include(">Resend<", ">Revoke<")

        get admin_event_dashboard_path(event.slug)
        expect(response.body).not_to include(new_invite_admin_event_participants_path(event.slug))
        expect(response.body).not_to include(new_admin_event_import_path(event.slug))

        get admin_event_integrations_path(event.slug)
        expect(response.body).not_to include(admin_event_api_tokens_path(event.slug))
        expect(response.body).to include("only event admins can create, rotate, or revoke them")
      end
    end
  end

  shared_examples "can add participants" do
    it "opens the invite form and sends an invitation" do
      get new_invite_admin_event_participants_path(event.slug)
      expect(response).to have_http_status(:ok)

      expect {
        post send_invite_admin_event_participants_path(event.slug),
          params: { invite: { email: "welcome@example.com" } }
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to redirect_to(admin_event_participants_path(event))
    end

    it "revokes an invitation" do
      invitation = create(:invitation, event: event)

      delete revoke_invite_admin_event_participants_path(event.slug, id: invitation.id)

      expect(Invitation.exists?(invitation.id)).to be(false)
    end

    it "starts a CSV import" do
      get new_admin_event_import_path(event.slug)
      expect(response).to have_http_status(:ok)

      expect {
        post admin_event_imports_path(event.slug), params: { csv_file: csv_upload }
      }.to change(ImportBatch, :count).by(1)
    end

    it "creates an event API token" do
      expect {
        post admin_event_api_tokens_path(event.slug), params: { name: "integration" }
      }.to change(EventApiToken, :count).by(1)
    end

    it "sees the invite, import, and token controls" do
      get admin_event_dashboard_path(event.slug)
      expect(response.body).to include(new_invite_admin_event_participants_path(event.slug))
      expect(response.body).to include(new_admin_event_import_path(event.slug))

      get admin_event_integrations_path(event.slug)
      expect(response.body).to include(admin_event_api_tokens_path(event.slug))
    end
  end

  context "as event admin" do
    before { sign_in_with_role("event_admin") }

    include_examples "can add participants"

    it "sees the controls on the participants page" do
      create(:invitation, event: event)

      get admin_event_participants_path(event.slug)
      expect(response.body).to include(new_invite_admin_event_participants_path(event.slug))
      expect(response.body).to include(new_admin_event_import_path(event.slug))

      get admin_event_participants_path(event.slug, status: "pending_invitations")
      expect(response.body).to include(">Resend<", ">Revoke<")
    end
  end

  context "as a series organizer" do
    before { sign_in_series_organizer }

    include_examples "can add participants"
  end

  describe "an import batch from another event" do
    it "is not reachable through this event's routes" do
      sign_in_with_role("event_admin")
      other_batch = ImportBatch.create!(event: create(:event), status: :previewing,
        total_count: 0, rows_data: [], send_invitations: false)

      get preview_admin_event_import_path(event.slug, other_batch)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("could not be found")
    end
  end
end
