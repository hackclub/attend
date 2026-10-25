require "rails_helper"

RSpec.describe "Admin::Participants", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:global_admin) { User.create!(email: "ga-participants@example.com", name: "Global Admin", global_role: "global_admin", admin_console_beta: false) }

  def complete_onboarding!(pe)
    pe.travels.create!(direction: "inbound", mode: "car")
    pe.travels.create!(direction: "outbound", mode: "car")
    pe.create_medical!
    pe.create_dietary!
    pe.create_accessibility!
    pe.create_safeguarding_info!
    create(:consent, participant_event: pe)
  end

  describe "GET index with flag=incomplete_onboarding" do
    before { sign_in global_admin }

    it "lists only participants with incomplete onboarding" do
      complete_pe = create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Complete", legal_last_name: "Person"))
      complete_onboarding!(complete_pe)
      incomplete_pe = create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Incomplete", legal_last_name: "Person"))

      get admin_event_participants_path(event.slug), params: { flag: "incomplete_onboarding" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(incomplete_pe.participant.full_name)
      expect(response.body).not_to include(complete_pe.participant.full_name)
    end

    it "combines with the checked_in filter without raising" do
      create(:participant_event, event: event)

      get admin_event_participants_path(event.slug),
        params: { flag: "incomplete_onboarding", checked_in: "yes" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "participants over the age limit" do
    let!(:aged_out) do
      create(:participant_event, event: event, status: :invited, skip_age_check: true,
        participant: create(:participant, legal_first_name: "Aged", legal_last_name: "Out", date_of_birth: event.ends_at.to_date - 25.years))
    end
    let!(:eligible) do
      create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Still", legal_last_name: "Eligible"))
    end

    it "lists only them under flag=over_age_limit, in both admin UIs" do
      [ false, true ].each do |console|
        global_admin.update!(admin_console_beta: console)
        sign_in global_admin

        get admin_event_participants_path(event.slug), params: { flag: "over_age_limit" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(aged_out.participant.full_name)
        expect(response.body).not_to include(eligible.participant.full_name)
      end
    end

    it "warns on their participant page, in both admin UIs" do
      [ false, true ].each do |console|
        global_admin.update!(admin_console_beta: console)
        sign_in global_admin

        get admin_event_participant_path(event.slug, aged_out)
        expect(Nokogiri::HTML(response.body).at_css("[data-testid='over-age-limit']")).to be_present

        get admin_event_participant_path(event.slug, eligible)
        expect(Nokogiri::HTML(response.body).at_css("[data-testid='over-age-limit']")).to be_nil
      end
    end
  end

  describe "accommodation when disabled for the event" do
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in global_admin }

    it "hides the Accommodation tab on the participant page" do
      get admin_event_participant_path(event, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(accommodation_admin_event_participant_path(event, participant_event))
    end

    it "redirects direct visits to the accommodation page" do
      get accommodation_admin_event_participant_path(event, participant_event)

      expect(response).to redirect_to(admin_event_participant_path(event, participant_event))
      expect(flash[:alert]).to include("Accommodation is disabled")
    end

    it "shows the tab and page when accommodation is enabled" do
      event.update!(accommodation_enabled: true)

      get admin_event_participant_path(event, participant_event)
      expect(response.body).to include(accommodation_admin_event_participant_path(event, participant_event))

      get accommodation_admin_event_participant_path(event, participant_event)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "Slack ID copy controls on the participant page" do
    let(:participant_event) do
      create(:participant_event, event: event, participant: create(:participant, slack_user_id: "U0SLACKID1"))
    end

    before { sign_in global_admin }

    shared_examples "Slack ID copy controls" do
      it "renders copy controls with the Slack ID, even before onboarding is complete" do
        get admin_event_participant_path(event, participant_event)

        expect(response).to have_http_status(:ok)
        page = Nokogiri::HTML(response.body)
        copy_buttons = page.css('button[data-controller="clipboard"][data-clipboard-content-value="U0SLACKID1"]')
        expect(copy_buttons.map { |b| b.text.strip }).to contain_exactly("Copy Slack ID", "Copy")
        expect(response.body).not_to include(invite_to_slack_channel_admin_event_participant_path(event, participant_event))
      end

      it "keeps Invite to Channel for complete registrations" do
        event.update!(slack_channel_id: "C123")
        participant_event.update!(status: :complete)

        get admin_event_participant_path(event, participant_event)

        expect(response.body).to include("Copy Slack ID")
        expect(response.body).to include(invite_to_slack_channel_admin_event_participant_path(event, participant_event))
      end

      it "does not render the copy controls or the Slack card without a Slack ID before completion" do
        participant_event.participant.update!(slack_user_id: nil)

        get admin_event_participant_path(event, participant_event)

        expect(response.body).not_to include("Copy Slack ID")
        expect(response.body).not_to match(/Slack integration/i)
      end
    end

    include_examples "Slack ID copy controls"

    context "with the admin console beta" do
      before { global_admin.update!(admin_console_beta: true) }

      include_examples "Slack ID copy controls"
    end
  end

  describe "GET travel" do
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in global_admin }

    it "renders both mode selectors with the targets and actions required by the travel form controller" do
      get travel_admin_event_participant_path(event, participant_event)

      expect(response).to have_http_status(:ok)
      form = Nokogiri::HTML(response.body).at_css("form[data-controller~='travel-form']")
      mode_selects = form.css("select[data-travel-form-target]").index_by { |select| select["data-travel-form-target"] }

      expect(mode_selects.keys).to include("inboundMode", "outboundMode")
      expect(mode_selects.values_at("inboundMode", "outboundMode").map { |select| select["data-action"] }).to eq([
        "change->travel-form#updateFields",
        "change->travel-form#updateFields"
      ])
    end
  end

  describe "POST sync_slack_channel" do
    include ActiveJob::TestHelper

    before { sign_in global_admin }

    it "enqueues the sync job instead of calling Slack in-request" do
      event.update!(slack_channel_id: "C123")

      expect {
        post sync_slack_channel_admin_event_participants_path(event.slug), params: { send_emails: "1" }
      }.to have_enqueued_job(SyncSlackChannelJob).with(event.id, send_emails: true)

      expect(response).to redirect_to(admin_event_participants_path(event.slug))
    end

    it "rejects events without a configured Slack channel" do
      expect {
        post sync_slack_channel_admin_event_participants_path(event.slug)
      }.not_to have_enqueued_job(SyncSlackChannelJob)

      expect(flash[:alert]).to include("No Slack channel")
    end
  end

  describe "GET consents" do
    let(:participant_event) { create(:participant_event, event: event) }

    before { sign_in global_admin }

    def get_consents
      get consents_admin_event_participant_path(event, participant_event)
    end

    it "lists an applicable custom document even when no consent row exists yet" do
      create(:custom_document, :physical, :minors_only, event: event, name: "Entry Authorization")

      get_consents

      expect(response.body).to include("Additional Documents")
      expect(response.body).to include("Entry Authorization")
      expect(response.body).to include("Awaiting participant upload")
    end

    it "shows an uploaded physical document as awaiting guardian confirmation" do
      doc = create(:custom_document, :physical, :dual_signer, event: event, name: "Entry Authorization")
      create(:guardian_participant_event, participant_event: participant_event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current)
      consent.physical_uploads.attach(io: StringIO.new("bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      get_consents

      expect(response.body).to include("Awaiting guardian confirmation")
      expect(response.body).to include("View Upload")
    end

    it "shows an untouched DocuSeal document as not started" do
      create(:custom_document, event: event, name: "Hotel Waiver")

      get_consents

      expect(response.body).to include("Hotel Waiver")
      expect(response.body).to include("Not started")
    end

    it "does not duplicate a custom document consent in the main consents table" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")
      create(:consent, :signed, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc)

      get_consents

      expect(response.body.scan("Hotel Waiver").count).to eq(1)
    end

    it "keeps consents for archived documents in the main consents table" do
      doc = create(:custom_document, :archived, event: event, name: "Old Form")
      create(:consent, :signed, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc)

      get_consents

      expect(response.body).to include("Old Form")
    end
  end

  describe "POST resend_invitation" do
    before { sign_in global_admin }

    # display_status is computed from the data, not the status column, so each
    # case has to be built out of the real onboarding shape — code of conduct
    # included, since accepting it is what "the participant has submitted"
    # means.
    def onboarded!(pe, waiver: :pending)
      pe.update!(code_of_conduct_accepted_at: Time.current)
      pe.travels.create!(direction: "inbound", mode: "car")
      pe.travels.create!(direction: "outbound", mode: "car")
      pe.create_medical!
      pe.create_dietary!
      pe.create_accessibility!
      pe.create_safeguarding_info!
      create(:consent, *(waiver == :signed ? [ :signed ] : []), participant_event: pe)
      pe
    end

    it "re-sends the onboarding invitation" do
      participant = create(:participant, email: "chase-me@example.com")
      pe = create(:participant_event, event: event, participant: participant, status: :in_progress)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(response).to redirect_to(admin_event_participant_path(event, pe))
      expect(flash[:notice]).to include(participant.email)
    end

    it "shows the action in the Actions dropdown while the participant still owes information" do
      pe = create(:participant_event, event: event, status: :in_progress)

      get admin_event_participant_path(event, pe)

      expect(response.body).to include(resend_invitation_admin_event_participant_path(event, pe))
    end

    it "hides the action once the outstanding part is the guardian's" do
      pe = onboarded!(create(:participant_event, event: event, status: :in_progress))
      create(:guardian_participant_event, participant_event: pe)

      get admin_event_participant_path(event, pe)

      expect(pe.reload.display_status).to eq("Awaiting Parent")
      expect(response.body).not_to include(resend_invitation_admin_event_participant_path(event, pe))
    end

    it "points at the guardian invite when the participant has already submitted" do
      pe = onboarded!(create(:participant_event, event: event, status: :in_progress))
      create(:guardian_participant_event, participant_event: pe)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(flash[:alert]).to include("guardian invite")
    end

    it "refuses to resend to a fully onboarded participant" do
      pe = onboarded!(create(:participant_event, event: event, status: :complete), waiver: :signed)
      create(:consent, :freedom_waiver, :signed, participant_event: pe)
      create(:guardian_participant_event, participant_event: pe, status: :completed)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(pe.reload.display_status).to eq("Complete")
      expect(flash[:alert]).to include("already finished onboarding")
    end

    # Since #86 the code of conduct is its own step, so an imported
    # participant whose guardian did everything still owes us something — and
    # the invitation link is how they get back in to give it.
    it "still offers the resend when only the code of conduct is missing" do
      pe = onboarded!(create(:participant_event, event: event, status: :in_progress), waiver: :signed)
      pe.update!(code_of_conduct_accepted_at: nil)
      create(:consent, :freedom_waiver, :signed, participant_event: pe)
      create(:guardian_participant_event, participant_event: pe, status: :completed)

      expect(pe.reload.display_status).to eq("Awaiting Participant")

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.to have_enqueued_mail(ParticipantMailer, :invitation)
    end

    it "refuses to resend to a withdrawn participant" do
      pe = create(:participant_event, event: event, status: :withdrawn)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(flash[:alert]).to include("withdrawn")
    end

    it "refuses to resend to a bouncing address" do
      participant = create(:participant, email: "bounces@example.com")
      participant.update!(email_undeliverable_at: Time.current)
      pe = create(:participant_event, event: event, participant: participant, status: :invited)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(flash[:alert]).to include("bouncing")
    end

    it "refuses to resend to a banned address" do
      participant = create(:participant, email: "banned-resend@example.com")
      pe = create(:participant_event, event: event, participant: participant, status: :invited)
      create(:ban, email: participant.email)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.not_to have_enqueued_mail(ParticipantMailer, :invitation)

      expect(flash[:alert]).to include("banned")
    end

    it "records an audit log entry" do
      pe = create(:participant_event, event: event, status: :in_progress)

      expect {
        post resend_invitation_admin_event_participant_path(event, pe)
      }.to change { AuditLog.where(action: "resend_invitation").count }.by(1)
    end
  end
  describe "DELETE destroy" do
    it "revokes the invitation so the removal cannot be undone by the old link" do
      participant = create(:participant, email: "removed@example.com")
      create(:invitation, event: event, email: "removed@example.com", sent_at: Time.current)
      participant_event = create(:participant_event, participant: participant, event: event)

      sign_in global_admin

      expect {
        delete admin_event_participant_path(event, participant_event)
      }.to change(Invitation, :count).by(-1)

      expect(ParticipantEvent.exists?(participant_event.id)).to be(false)
      expect(Invitation.where(event: event).for_email("removed@example.com")).to be_empty
    end

    it "keeps the invitation when the registration is only withdrawn" do
      participant = create(:participant, email: "staying@example.com")
      create(:invitation, event: event, email: "staying@example.com", sent_at: Time.current)
      participant_event = create(:participant_event, participant: participant, event: event)

      sign_in global_admin

      expect {
        post withdraw_admin_event_participant_path(event, participant_event)
      }.not_to change(Invitation, :count)

      expect(participant_event.reload).to be_withdrawn
    end
  end

  describe "food-allergy information" do
    let(:participant_event) { create(:participant_event, event: event) }

    def medical_summary
      Nokogiri::HTML(response.body).at_css("[data-testid='medical-summary']").text.squish
    end

    it "flags allergies from both health records in the medical summary, in both admin UIs" do
      participant_event.create_medical!(allergies: "Penicillin", has_anaphylaxis_risk: true, requires_refrigeration: true)
      participant_event.create_dietary!(life_threatening_allergies: "Peanuts", cross_contamination_risk: true)

      [ false, true ].each do |console|
        global_admin.update!(admin_console_beta: console)
        sign_in global_admin

        get admin_event_participant_path(event, participant_event)

        expect(medical_summary).to match(/anaphylaxis risk/i).and match(/life-threatening food allergies/i)
          .and match(/cross-contamination risk/i).and match(/has allergies/i).and match(/needs refrigeration/i)
        expect(medical_summary).not_to match(/no special medical flags|Peanuts|Penicillin/i)
      end
    end

    it "reads \"None\" in the allergy fields as no allergy" do
      participant_event.create_medical!(allergies: "None")
      participant_event.create_dietary!(life_threatening_allergies: "None")

      [ false, true ].each do |console|
        global_admin.update!(admin_console_beta: console)
        sign_in global_admin

        get admin_event_participant_path(event, participant_event)

        expect(medical_summary).to match(/no special medical flags/i)
      end
    end

    it "shows dietary food allergies and cross-contamination in the table, in both admin UIs" do
      participant_event.create_dietary!(life_threatening_allergies: "Peanuts", cross_contamination_risk: true)
      create(:participant_event, event: event).create_dietary!(life_threatening_allergies: "None")
      create(:participant_event, event: event)

      [ false, true ].each do |console|
        global_admin.update!(admin_console_beta: console)
        sign_in global_admin

        get table_admin_event_participants_path(event)

        doc = Nokogiri::HTML(response.body)
        expect(doc.css("th[data-column='food_allergies'], th[data-column='cross_contamination']").size).to eq(2)
        expect(doc.css("td[data-column='food_allergies']").map { |td| td.text.strip }).to contain_exactly("Peanuts", "—", "—")
        expect(doc.css("td[data-column='cross_contamination']").map { |td| td.text.strip }).to contain_exactly("Yes", "No", "—")
        expect(doc.css("tr[data-group-id] td").map { |td| td["colspan"].to_i }.uniq).to eq([ doc.css("thead th").size ])
      end
    end
  end
end
