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

  describe "the admin participants table" do
    let(:admin) { User.create!(email: "admin-table@example.com", name: "Admin", global_role: "global_admin") }
    let!(:doc) { create(:custom_document, :optional, event: event, name: "Zip Lining Waiver") }

    # One participant per state, named so the rendered table can be read back.
    let!(:signed_pe) { participant_named("Signa", "Signed") }
    let!(:awaiting_pe) { participant_named("Awaita", "Awaiting") }
    let!(:withdrawn_pe) { participant_named("Withda", "Withdrawn") }
    let!(:absent_pe) { participant_named("Absenta", "Absent") }

    def participant_named(first, last)
      create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: first, legal_last_name: last))
    end

    before do
      sign_in admin
      create(:consent, :signed, participant_event: signed_pe, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)
      create(:consent, participant_event: awaiting_pe, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)
      create(:consent, participant_event: withdrawn_pe, consent_type: :custom_document,
        custom_document: doc, opted_in_at: 1.day.ago, withdrawn_at: Time.current)
    end

    def table_get(params = {})
      get table_admin_event_participants_path(event.slug), params: params
    end

    def filter_params(operator, value = doc.id)
      { filters: { "0" => { field: "optional_document", operator: operator, value: value } } }
    end

    it "gives each optional document its own sortable column" do
      table_get

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).to include("optional_document:#{doc.id}")
      expect(response.body).to include("Awaiting signature")
      expect(response.body).to include("Not added")
    end

    it "filters to participants who added it" do
      table_get(filter_params("added"))

      expect(response.body).to include("Signa", "Awaita")
      expect(response.body).not_to include("Absenta")
      # Withdrawn is not "added" — that's the whole point of keeping the row.
      expect(response.body).not_to include("Withda")
    end

    it "filters to participants who have not added it" do
      table_get(filter_params("not_added"))

      expect(response.body).to include("Absenta", "Withda")
      expect(response.body).not_to include("Signa")
      expect(response.body).not_to include("Awaita")
    end

    it "filters to those still owing a signature" do
      table_get(filter_params("awaiting"))

      expect(response.body).to include("Awaita")
      expect(response.body).not_to include("Signa")
      expect(response.body).not_to include("Absenta")
    end

    it "filters to those who have signed" do
      table_get(filter_params("signed"))

      expect(response.body).to include("Signa")
      expect(response.body).not_to include("Awaita")
    end

    it "filters to those who backed out" do
      table_get(filter_params("withdrawn"))

      expect(response.body).to include("Withda")
      expect(response.body).not_to include("Signa")
      expect(response.body).not_to include("Absenta")
    end

    it "ignores a document belonging to another event" do
      other_doc = create(:custom_document, :optional, event: create(:event), name: "Someone Else's Waiver")

      table_get(filter_params("added", other_doc.id))

      # Unresolvable document: the filter is dropped rather than silently
      # matching across events.
      expect(response.body).to include("Signa", "Absenta")
    end

    it "sorts signed first, then awaiting, then withdrawn, then not added" do
      table_get(sort: "optional_document:#{doc.id}", direction: "asc")

      body = response.body
      expect(body.index("Signa")).to be < body.index("Awaita")
      expect(body.index("Awaita")).to be < body.index("Withda")
      expect(body.index("Withda")).to be < body.index("Absenta")
    end

    it "reverses that order on a descending sort" do
      table_get(sort: "optional_document:#{doc.id}", direction: "desc")

      body = response.body
      expect(body.index("Absenta")).to be < body.index("Signa")
    end

    it "groups participants by where they stand on it" do
      table_get(group_by: "optional_document:#{doc.id}")

      expect(response).to have_http_status(:ok)
      # Assert on the group header rows, not the cell badges, which carry the
      # same words.
      expect(response.body).to include('data-group-id="signed"')
      expect(response.body).to include('data-group-id="awaiting-signature"')
      expect(response.body).to include('data-group-id="removed"')
      expect(response.body).to include('data-group-id="not-added"')
      # The dropdown labels the current grouping by name, not a raw UUID.
      expect(response.body).to include("Zip Lining Waiver")
      expect(response.body).not_to include("Optional Document:#{doc.id}".titleize)
    end

    it "falls back to the default sort for an unknown document key" do
      table_get(sort: "optional_document:#{SecureRandom.uuid}")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the admin participants list" do
    let(:admin) { User.create!(email: "admin-list@example.com", name: "Admin", global_role: "global_admin") }
    let!(:doc) { create(:custom_document, :optional, event: event, name: "Zip Lining Waiver") }
    let!(:added_pe) do
      create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Addy", legal_last_name: "Added"))
    end
    let!(:absent_pe) do
      create(:participant_event, event: event,
        participant: create(:participant, legal_first_name: "Absenta", legal_last_name: "Absent"))
    end

    before do
      sign_in admin
      create(:consent, participant_event: added_pe, consent_type: :custom_document,
        custom_document: doc, opted_in_at: Time.current)
    end

    it "offers an optional-document filter only when the event has one" do
      get admin_event_participants_path(event.slug)

      expect(response.body).to include("All Optional Docs")
      expect(response.body).to include("Zip Lining Waiver: added")
    end

    it "filters the list down to participants who added it" do
      get admin_event_participants_path(event.slug), params: { optional_document: "#{doc.id}:added" }

      expect(response.body).to include("Addy")
      expect(response.body).not_to include("Absenta")
    end

    it "filters the list down to participants who did not" do
      get admin_event_participants_path(event.slug), params: { optional_document: "#{doc.id}:not_added" }

      expect(response.body).to include("Absenta")
      expect(response.body).not_to include("Addy")
    end
  end

  describe "exports" do
    it "reports which optional documents a participant took up" do
      doc = create(:custom_document, :optional, event: event, name: "Zip Lining Waiver")
      other = create(:custom_document, :optional, event: event, name: "Hiking Waiver")
      required = create(:custom_document, event: event, name: "Hotel Waiver")
      pe = create(:participant_event, event: event)
      create(:consent, :signed, participant_event: pe, consent_type: :custom_document, custom_document: doc)
      create(:consent, participant_event: pe, consent_type: :custom_document, custom_document: other)
      create(:consent, participant_event: pe, consent_type: :custom_document, custom_document: required)

      added = Exports::FieldRegistry::FIELDS.fetch("participant_event.optional_documents_added")
      pending = Exports::FieldRegistry::FIELDS.fetch("participant_event.optional_documents_pending")

      expect(added.extractor.call(pe.reload)).to eq("Hiking Waiver, Zip Lining Waiver")
      # The required document is not an opt-in and never belongs in this column.
      expect(pending.extractor.call(pe)).to eq("Hiking Waiver")
    end

    it "leaves the columns empty for a participant who added nothing" do
      create(:custom_document, :optional, event: event)
      pe = create(:participant_event, event: event)

      added = Exports::FieldRegistry::FIELDS.fetch("participant_event.optional_documents_added")

      expect(added.extractor.call(pe)).to be_nil
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
