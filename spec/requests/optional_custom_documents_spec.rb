require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change
RSpec::Matchers.define_negated_matcher :not_have_enqueued_mail, :have_enqueued_mail

# Optional custom documents cover opt-in activities (zip lining, a hike). The
# behaviour that matters most is negative: until the participant adds one,
# nobody — the guardian above all — is shown it or asked to sign it.
RSpec.describe "Optional custom documents", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  # Freedom waivers default on; disable them so custom documents are the only
  # thing gating minors in these specs.
  let(:event) { create(:event, freedom_waivers_enabled: false) }

  describe "admin management" do
    let(:admin) { User.create!(email: "admin-optional@example.com", name: "Admin", global_role: "global_admin") }

    before { sign_in admin }

    it "creates an optional document" do
      post admin_event_custom_documents_path(event), params: {
        custom_document: { name: "Zip Lining Waiver", docuseal_template_id: "1234",
                           signer_type: "minor_and_guardian", optional: "1" }
      }

      doc = event.custom_documents.last
      expect(doc).to be_optional
      expect(flash[:notice]).to include("until a participant adds it themselves")
    end

    it "defaults to a required document when the box is left unticked" do
      post admin_event_custom_documents_path(event), params: {
        custom_document: { name: "Hotel Waiver", docuseal_template_id: "1234", signer_type: "participant" }
      }

      expect(event.custom_documents.last).not_to be_optional
    end

    it "flags optional documents on the integrations page with a take-up count" do
      doc = create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")
      create(:consent, participant_event: create(:participant_event, event: event),
        consent_type: :custom_document, custom_document: doc, opted_in_at: Time.current)

      get admin_event_integrations_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).to include("Optional")
      expect(response.body).to include("1 participant so far")
    end

    it "lists optional documents a participant hasn't added on their consents page" do
      create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")
      participant_event = create(:participant_event, event: event)

      get consents_admin_event_participant_path(event, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Optional Documents Not Added")
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).to include("nothing has been sent to their parent/guardian")
    end

    it "does not reopen completed participants when an optional document is added" do
      create(:participant_event, event: event, status: :complete)

      expect {
        create(:custom_document, :optional, event: event)
      }.not_to have_enqueued_job(ReopenParticipantsForCustomDocumentsJob)

      expect {
        create(:custom_document, event: event)
      }.to have_enqueued_job(ReopenParticipantsForCustomDocumentsJob)
    end
  end

  describe "the guardian portal" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
    let(:token) { gpe.generate_invite_token! }
    let!(:doc) do
      create(:custom_document, :optional, :minors_only, event: event, name: "Zip Lining Waiver")
    end

    it "never mentions an optional document the participant hasn't added" do
      get guardian_portal_step_path(token: token, step: "consents")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Zip Lining Waiver")
    end

    it "turns away a guardian who reaches the document's page directly" do
      expect {
        get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)
      }.not_to change(Consent, :count)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(flash[:alert]).to include("doesn't need your signature")
      expect(DocusealJobs::CreateCustomDocumentJob).not_to have_been_enqueued
    end

    it "shows it once the participant has added it" do
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)

      get guardian_portal_step_path(token: token, step: "consents")

      expect(response.body).to include("Zip Lining Waiver")
    end

    it "hides it again if the participant backs out" do
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, opted_in_at: 1.day.ago, withdrawn_at: Time.current)

      get guardian_portal_step_path(token: token, step: "consents")

      expect(response.body).not_to include("Zip Lining Waiver")
    end

    it "does not create a submission for an un-added document when the portal is completed" do
      gpe.guardian.update!(legal_first_name: "Pat", legal_last_name: "Guardian", phone: "+15555550100")
      gpe.emergency_contacts.create!(name: "Pat Guardian", phone: "+15555550100", relationship: "Parent")
      create(:consent, :signed, participant_event: participant_event, guardian_signed_at: Time.current)

      expect {
        post guardian_portal_complete_path(token: token)
      }.not_to change { participant_event.consents.where.not(custom_document_id: nil).count }

      expect(DocusealJobs::CreateCustomDocumentJob).not_to have_been_enqueued
    end
  end

  describe "a participant adding and removing one" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) do
      create(:participant_event, participant: participant, event: event, status: :complete)
    end
    let!(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }

    before { sign_in user }

    it "offers it on the dashboard without asking for a signature yet" do
      create(:custom_document, :optional, :minors_only, event: event, name: "Zip Lining Waiver")

      get dashboard_event_path(participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).to include("Add and sign")
      expect(participant_event.consents).to be_empty
    end

    it "refuses to open the signing page before it's added, creating nothing" do
      doc = create(:custom_document, :optional, event: event)

      expect {
        get dashboard_sign_document_path(participant_event, doc)
      }.not_to change(Consent, :count)

      expect(response).to redirect_to(dashboard_event_path(participant_event))
    end

    it "adds it, records the opt-in, and sends the participant to sign" do
      doc = create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.to change(participant_event.consents, :count).by(1)

      consent = participant_event.consents.last
      expect(consent.custom_document).to eq(doc)
      expect(consent.opted_in_at).to be_present
      expect(consent.withdrawn_at).to be_nil
      expect(response).to redirect_to(dashboard_sign_document_path(participant_event, doc))
    end

    it "reopens a participant who had already finished" do
      doc = create(:custom_document, :optional, event: event)

      post dashboard_add_optional_document_path(participant_event, doc)

      expect(participant_event.reload.status).to eq("in_progress")
    end

    it "keeps the added document on the dashboard after that reopening" do
      participant_event.update!(onboarding_completed_at: Time.current)
      doc = create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")
      post dashboard_add_optional_document_path(participant_event, doc)

      get dashboard_event_path(participant_event)

      expect(participant_event.reload.status).to eq("in_progress")
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).to include("Not taking part any more")
    end

    it "withdraws without destroying the consent, then re-completes the participant" do
      doc = create(:custom_document, :optional, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)
      participant_event.update!(status: :in_progress, code_of_conduct_accepted_at: Time.current)
      create(:consent, :signed, participant_event: participant_event)
      gpe.update!(status: :completed, completed_at: Time.current)

      expect {
        delete dashboard_withdraw_optional_document_path(participant_event, doc)
      }.not_to change(Consent, :count)

      expect(consent.reload.withdrawn_at).to be_present
      expect(participant_event.reload.status).to eq("complete")
    end

    it "keeps a signature on file when a signed document is withdrawn" do
      doc = create(:custom_document, :optional, event: event)
      consent = create(:consent, :signed, participant_event: participant_event,
        consent_type: :custom_document, custom_document: doc, opted_in_at: Time.current)

      delete dashboard_withdraw_optional_document_path(participant_event, doc)

      expect(consent.reload).to be_withdrawn
      expect(consent.status).to eq("signed")
      expect(consent.signed_at).to be_present
    end

    it "restores what was already signed when it's added back" do
      doc = create(:custom_document, :optional, event: event)
      consent = create(:consent, :signed, participant_event: participant_event,
        consent_type: :custom_document, custom_document: doc,
        opted_in_at: 2.days.ago, withdrawn_at: 1.day.ago)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.not_to change(Consent, :count)

      expect(consent.reload).not_to be_withdrawn
      expect(consent.status).to eq("signed")
    end

    it "refuses to add a document that isn't optional" do
      doc = create(:custom_document, event: event)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.not_to change(Consent, :count)

      expect(flash[:alert]).to include("isn't available to add")
    end

    it "does not offer an under-18s-only document to an adult" do
      participant.update!(date_of_birth: 25.years.ago)
      create(:custom_document, :optional, :minors_only, event: event, name: "Zip Lining Waiver")

      get dashboard_event_path(participant_event)

      expect(response.body).not_to include("Zip Lining Waiver")
    end

    it "won't let someone else add a document to a participant event they don't own" do
      doc = create(:custom_document, :optional, event: event)
      other_user = create(:user)
      create(:participant, user: other_user)
      sign_in other_user

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.not_to change(Consent, :count)

      expect(response).to redirect_to(root_path)
    end
  end

  describe "telling a guardian who already finished" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) do
      create(:participant_event, participant: participant, event: event, status: :complete)
    end
    let!(:doc) { create(:custom_document, :optional, :minors_only, event: event, name: "Zip Lining Waiver") }

    before { sign_in user }

    it "emails a guardian who has already completed their portal" do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.to have_enqueued_mail(GuardianMailer, :optional_document_added)
    end

    it "does not email again when the same document is added twice" do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)
      post dashboard_add_optional_document_path(participant_event, doc)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.to not_have_enqueued_mail(GuardianMailer, :optional_document_added)
        .and not_change(Consent, :count)
    end

    it "stays quiet when the guardian is still working through the portal" do
      create(:guardian_participant_event, participant_event: participant_event, status: :in_progress)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.not_to have_enqueued_mail(GuardianMailer, :optional_document_added)
    end

    it "stays quiet for a participant-only document" do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)
      participant_doc = create(:custom_document, :optional, event: event)

      expect {
        post dashboard_add_optional_document_path(participant_event, participant_doc)
      }.not_to have_enqueued_mail(GuardianMailer, :optional_document_added)
    end

    it "stays quiet while guardian invites are locked" do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)
      event.update!(guardian_invites_locked: true)

      expect {
        post dashboard_add_optional_document_path(participant_event, doc)
      }.not_to have_enqueued_mail(GuardianMailer, :optional_document_added)
    end
  end

  describe "the onboarding documents step" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) do
      create(:participant_event, participant: participant, event: event,
        onboarding_step: 10, status: :in_progress)
    end

    before do
      sign_in user
      create(:guardian_participant_event, participant_event: participant_event)
      # An already-signed waiver so optional documents are the only open item.
      create(:consent, :signed, participant_event: participant_event)
    end

    it "offers optional documents without blocking the step" do
      create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")

      get onboarding_step_path(step: "documents", event_id: event.id)

      expect(response.body).to include("Optional extras")
      expect(response.body).to include("Zip Lining Waiver")
      # The step is still passable — an optional document nobody added can't
      # be what's holding the participant up.
      expect(response.body).to include("Continue to Review")
      expect(response.body).not_to include("cursor-not-allowed")
      expect(participant_event.reload.consents.where.not(custom_document_id: nil)).to be_empty
    end

    it "adds one from the wizard and then blocks until it's signed" do
      doc = create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")

      expect {
        post onboarding_add_optional_document_path(custom_document_id: doc.id, event_id: event.id)
      }.to change(participant_event.consents, :count).by(1)

      expect(participant_event.reload.eligible_for_completion?).to be false

      delete onboarding_withdraw_optional_document_path(custom_document_id: doc.id, event_id: event.id)

      expect(participant_event.reload.consents.find_by(custom_document: doc)).to be_withdrawn
    end
  end

  describe "completion" do
    let(:participant_event) do
      create(:participant_event, event: event, code_of_conduct_accepted_at: Time.current)
    end
    let!(:gpe) do
      create(:guardian_participant_event, participant_event: participant_event,
        status: :completed, completed_at: Time.current)
    end

    before { create(:consent, :signed, participant_event: participant_event) }

    it "ignores an optional document nobody added" do
      create(:custom_document, :optional, event: event)

      expect(participant_event.eligible_for_completion?).to be true
    end

    it "blocks once the participant adds it, and clears again when signed" do
      doc = create(:custom_document, :optional, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)

      expect(participant_event.reset_document_memoisation!.eligible_for_completion?).to be false

      consent.update!(status: :signed, signed_at: Time.current)

      expect(participant_event.reload.reset_document_memoisation!.eligible_for_completion?).to be true
    end
  end
end
