require "rails_helper"

# An event can hold onboarding invitations: participants are added (form, API,
# import) and show up for staff, but nobody is emailed until the event, or
# series HQ for every event at once, sends the held invitations.
RSpec.describe "Onboarding invitations held", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:series) { create(:event_series, name: "Sunbeam", slug: "sunbeam-held-spec") }
  let(:event) { create(:event, event_series: series, onboarding_invites_held: true) }
  let(:global_admin) { User.create!(email: "ga-held@example.com", name: "Global Admin", global_role: "global_admin") }
  let(:owner) do
    User.create!(email: "owner-held@example.com", name: "Owner").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "owner")
    end
  end
  let(:organizer) do
    User.create!(email: "organizer-held@example.com", name: "Organizer").tap do |user|
      SeriesRoleAssignment.create!(user: user, event_series: series, role: "organizer")
    end
  end

  describe "Event" do
    it "sends the held invitations when the hold is released" do
      expect {
        event.update!(onboarding_invites_held: false)
      }.to have_enqueued_job(SendHeldOnboardingInvitesJob).with(event.id)
    end

    it "does not send when other config changes while still held" do
      expect {
        event.update!(travel_enabled: false)
      }.not_to have_enqueued_job(SendHeldOnboardingInvitesJob)
    end

    it "release_onboarding_invites! also works on an event that never held" do
      open_event = create(:event)
      create(:invitation, event: open_event, sent_at: nil)

      expect {
        open_event.release_onboarding_invites!
      }.to have_enqueued_job(SendHeldOnboardingInvitesJob).with(open_event.id)
    end
  end

  describe "admin invite form" do
    before { sign_in global_admin }

    it "adds the participant without emailing them" do
      expect {
        post send_invite_admin_event_participants_path(event.slug), params: { invite: { email: "kid@example.com", name: "Kid Person" } }
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      invitation = event.invitations.sole
      expect(invitation).to be_held
      expect(invitation.name).to eq("Kid Person")
      expect(response).to redirect_to(admin_event_participants_path(event.slug, status: "pending_invitations"))
      expect(flash[:notice]).to include("held")
    end

    it "lists them as held on the pending invitations tab, with a send button and the banner" do
      create(:invitation, event: event, email: "kid@example.com", sent_at: nil)

      get admin_event_participants_path(event.slug, status: "pending_invitations")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("kid@example.com")
      expect(response.body).to include(">Held<")
      expect(response.body).to include("Send now")
      expect(response.body).to include("held-invitations-banner")
      expect(response.body).to include(send_held_invitations_admin_event_participants_path(event.slug))
    end

    it "lets staff revoke a held invitation" do
      invitation = create(:invitation, event: event, email: "kid@example.com", sent_at: nil)

      delete revoke_invite_admin_event_participants_path(event.slug, id: invitation.id)

      expect(Invitation.exists?(invitation.id)).to be(false)
    end

    it "sends one held invitation on its own when a staff member asks" do
      create(:invitation, event: event, email: "kid@example.com", sent_at: nil)

      expect {
        post send_invite_admin_event_participants_path(event.slug), params: { invite: { email: "kid@example.com", send_now: "1" } }
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(event.invitations.count).to eq(1)
    end

    it "sends every held invitation and stops holding from the participants page" do
      create(:invitation, event: event, email: "one@example.com", sent_at: nil)
      create(:invitation, event: event, email: "two@example.com", sent_at: nil)

      expect {
        post send_held_invitations_admin_event_participants_path(event.slug)
      }.to have_enqueued_job(SendHeldOnboardingInvitesJob).with(event.id)
        .and change { AuditLog.where(action: "send_held_invitations").count }.by(1)

      expect(event.reload.onboarding_invites_held?).to be(false)
      expect(flash[:notice]).to include("2 held invitations")
    end

    it "still lets staff send an imported participant's invitation individually" do
      participant = create(:participant, email: "imported@example.com")
      pe = create(:participant_event, event: event, participant: participant, status: :invited)
      create(:invitation, event: event, email: participant.email, sent_at: nil)

      expect {
        post resend_invitation_admin_event_participant_path(event.slug, pe)
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(flash[:notice]).to eq("Invitation sent to imported@example.com.")
    end
  end

  describe "CSV import" do
    before { sign_in global_admin }

    let(:csv) do
      <<~CSV
        Email,First Name,Last Name
        row@example.com,Row,Person
      CSV
    end

    it "never emails on a held event, whatever the checkbox says, and records held invitations" do
      file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "people.csv")

      post admin_event_imports_path(event.slug), params: { csv_file: file, send_invitations: "1" }
      batch = ImportBatch.last
      expect(batch.send_invitations).to be(false)

      expect {
        ProcessImportBatchJob.perform_now(batch.id)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(event.participants.pluck(:email)).to eq([ "row@example.com" ])
      expect(event.invitations.held.pluck(:email)).to eq([ "row@example.com" ])
      expect(batch.reload).to be_completed
    end

    it "records held invitations for a silent import on an event that isn't holding" do
      open_event = create(:event)
      batch = ImportBatch.create!(event: open_event, status: :pending, total_count: 1, send_invitations: false,
        rows_data: [ { email: "silent@example.com", legal_first_name: "Si", legal_last_name: "Lent" } ])

      expect {
        ProcessImportBatchJob.perform_now(batch.id)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(open_event.invitations.held.pluck(:email)).to eq([ "silent@example.com" ])
    end

    it "shows the hold instead of the checkbox on the import page" do
      get new_admin_event_import_path(event.slug)

      expect(response.body).to include("Onboarding invitations are held")
      expect(response.body).not_to include('name="send_invitations"')
    end
  end

  describe "the public API" do
    let(:api_key) do
      event.generate_api_key!
      event.api_key
    end

    it "records the invitation as held and says so" do
      expect {
        post "/api/v1/events/#{event.id}/participants",
          params: { email: "api@example.com", first_name: "Api" },
          headers: { "Authorization" => "Bearer #{api_key}" }
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["held"]).to be(true)
      expect(body["message"]).to include("held")
      expect(event.invitations.held.sole.name).to eq("Api")
    end

    it "reports the module flag" do
      key = SeriesApiToken.generate_for(series, user: owner, name: "ops").token

      get "/api/v1/series/current/events/#{event.id}", headers: { "Authorization" => "Bearer #{key}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("event", "modules", "onboarding_invites_held")).to be(true)
    end
  end

  describe "series HQ" do
    let!(:other_event) { create(:event, event_series: series, onboarding_invites_held: true) }
    let!(:open_event) { create(:event, event_series: series) }

    it "shows the held panel with per-event counts" do
      create(:invitation, event: event, sent_at: nil)
      create(:invitation, event: event, sent_at: nil)
      create(:invitation, event: other_event, sent_at: nil)
      sign_in owner

      get admin_series_path(series)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("series-held-invitations")
      expect(response.body).to include("3 onboarding invitations held across 2 events")
      expect(response.body).to include(send_held_invitations_admin_series_path(series))
    end

    it "keeps the chase list's unaccepted count to invitations that were actually sent" do
      create(:invitation, event: event, sent_at: nil)
      create(:invitation, event: open_event, sent_at: 2.days.ago)
      sign_in owner

      get admin_series_path(series)

      expect(response.body).to include("invitation haven't been accepted yet")
      expect(response.body).not_to include("2 invitations haven't been accepted yet")
    end

    it "hides the panel from a series that doesn't use the hold" do
      quiet_series = create(:event_series, name: "Quiet", slug: "quiet-held-spec")
      create(:event, event_series: quiet_series)
      sign_in global_admin

      get admin_series_path(quiet_series)

      expect(response.body).not_to include("series-held-invitations")
    end

    it "lets an owner send every held invitation across the series" do
      create(:invitation, event: event, sent_at: nil)
      create(:invitation, event: other_event, sent_at: nil)
      sign_in owner

      expect {
        post send_held_invitations_admin_series_path(series)
      }.to have_enqueued_job(SendHeldOnboardingInvitesJob).with(event.id)
        .and have_enqueued_job(SendHeldOnboardingInvitesJob).with(other_event.id)
        .and change { AuditLog.where(action: "send_held_invitations").count }.by(1)

      expect(enqueued_jobs.count { |job| job["job_class"] == "SendHeldOnboardingInvitesJob" }).to eq(2)
      expect(event.reload.onboarding_invites_held?).to be(false)
      expect(other_event.reload.onboarding_invites_held?).to be(false)
      expect(response).to redirect_to(admin_series_path(series))
      expect(flash[:notice]).to include("2 held invitations across 2 events")
    end

    it "does not let an organizer release the series" do
      create(:invitation, event: event, sent_at: nil)
      sign_in organizer

      expect {
        post send_held_invitations_admin_series_path(series)
      }.not_to have_enqueued_job(SendHeldOnboardingInvitesJob)

      expect(response).to redirect_to(root_path)
      expect(event.reload.onboarding_invites_held?).to be(true)
    end
  end

  describe "the participant" do
    let(:user) { create(:user, email: "kid@example.com") }
    let(:participant) { create(:participant, user: user, email: user.email) }

    before { sign_in user }

    it "does not see a held invitation on their dashboard" do
      participant
      create(:invitation, event: event, email: "kid@example.com", sent_at: nil)

      get dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(event.name)
    end

    it "sees the invitation once it has been sent" do
      participant
      create(:invitation, event: event, email: "kid@example.com", sent_at: 1.hour.ago)

      get dashboard_path

      expect(response.body).to include(event.name)
      expect(response.body).to include("Complete registration")
    end

    it "cannot start onboarding off a held invitation" do
      participant
      create(:invitation, event: event, email: "kid@example.com", sent_at: nil)

      get onboarding_path(event_id: event.id)

      expect(response).to redirect_to(dashboard_path)
      expect(flash[:alert]).to include("don't have an invitation")
    end

    it "is told registration isn't open when imported onto a held event" do
      pe = create(:participant_event, event: event, participant: participant, status: :invited)

      get dashboard_event_path(pe)
      expect(response.body).to include("Registration opens soon")
      expect(response.body).not_to include("Continue registration")

      get onboarding_path(event_id: event.id)
      expect(response).to redirect_to(dashboard_path)
      expect(flash[:alert]).to include("isn't open yet")
      expect(pe.reload).to be_invited
    end

    it "gets in once a staff member has sent their invitation individually" do
      create(:participant_event, event: event, participant: participant, status: :invited)
      create(:invitation, event: event, email: "kid@example.com", sent_at: 1.hour.ago)

      get onboarding_path(event_id: event.id)

      expect(response).to redirect_to(onboarding_step_path(step: "profile", event_id: event.id))
    end
  end
end
