require "rails_helper"

RSpec.describe "Custom documents", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }

  describe "admin management" do
    let(:admin) { User.create!(email: "admin-docs@example.com", name: "Admin", global_role: "global_admin") }

    before { sign_in admin }

    it "lists custom documents on the integrations page" do
      create(:custom_document, event: event, name: "Hotel Waiver")

      get admin_event_integrations_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hotel Waiver")
    end

    it "creates a custom document" do
      expect {
        post admin_event_custom_documents_path(event), params: {
          custom_document: { name: "Hotel Waiver", docuseal_template_id: "1234", signer_type: "participant_and_guardian" }
        }
      }.to change(event.custom_documents, :count).by(1)

      doc = event.custom_documents.last
      expect(doc.name).to eq("Hotel Waiver")
      expect(doc.signer_type).to eq("participant_and_guardian")
      expect(response).to redirect_to(admin_event_integrations_path(event))
    end

    it "links to the edit page from the integrations list" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")

      get admin_event_integrations_path(event)

      expect(response.body).to include(admin_event_custom_document_edit_path(event, doc))
    end

    it "renders the edit form" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")

      get admin_event_custom_document_edit_path(event, doc)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit Hotel Waiver")
      expect(response.body).to include("Who signs?")
    end

    it "updates the name, description and signer type when nobody has signed" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver", signer_type: "participant")

      patch admin_event_custom_document_path(event, doc), params: {
        custom_document: { name: "Hotel Indemnity", description: "Sign page 2", signer_type: "participant_and_guardian" }
      }

      expect(response).to redirect_to(admin_event_integrations_path(event))
      expect(doc.reload).to have_attributes(
        name: "Hotel Indemnity",
        description: "Sign page 2",
        signer_type: "participant_and_guardian"
      )
    end

    it "keeps the signing setup but still renames once a consent exists" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver", signer_type: "participant",
        docuseal_template_id: "1234")
      create(:consent, :custom_document, custom_document: doc,
        participant_event: create(:participant_event, event: event))

      patch admin_event_custom_document_path(event, doc), params: {
        custom_document: { name: "Hotel Waiver (2026)", signer_type: "guardian", docuseal_template_id: "9999" }
      }

      expect(doc.reload).to have_attributes(
        name: "Hotel Waiver (2026)",
        signer_type: "participant",
        docuseal_template_id: "1234"
      )
    end

    it "shows the edit form without the signing fields once a consent exists" do
      doc = create(:custom_document, event: event)
      create(:consent, :custom_document, custom_document: doc,
        participant_event: create(:participant_event, event: event))

      get admin_event_custom_document_edit_path(event, doc)

      expect(response.body).to include("Signing setup is locked")
      expect(response.body).not_to include("Who signs?")
    end

    it "drops stale field mappings when the template changes" do
      doc = create(:custom_document, event: event, docuseal_template_id: "1234")
      event.update!(docuseal_field_mappings: {
        doc.mapping_key => { "mappings" => [ { "field_name" => "Name", "source_key" => "participant.full_name" } ] }
      })

      patch admin_event_custom_document_path(event, doc), params: {
        custom_document: { name: doc.name, docuseal_template_id: "5678" }
      }

      expect(doc.reload.docuseal_template_id).to eq("5678")
      expect(event.reload.docuseal_field_mappings).not_to have_key(doc.mapping_key)
    end

    it "reopens completed participants when an optional document becomes required" do
      doc = create(:custom_document, event: event, optional: true)

      expect {
        patch admin_event_custom_document_path(event, doc), params: {
          custom_document: { name: doc.name, docuseal_template_id: doc.docuseal_template_id, optional: "0" }
        }
      }.to have_enqueued_job(ReopenParticipantsForCustomDocumentsJob).with(event.id)

      expect(doc.reload).not_to be_optional
    end

    it "rejects an invalid update instead of saving it" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")

      patch admin_event_custom_document_path(event, doc), params: {
        custom_document: { name: "", docuseal_template_id: doc.docuseal_template_id }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(doc.reload.name).to eq("Hotel Waiver")
    end

    it "destroys a document without consents but archives one with consents" do
      unused = create(:custom_document, event: event)
      used = create(:custom_document, event: event)
      create(:consent, :custom_document, custom_document: used,
        participant_event: create(:participant_event, event: event))

      expect {
        delete admin_event_custom_document_path(event, unused)
      }.to change(CustomDocument, :count).by(-1)

      expect {
        delete admin_event_custom_document_path(event, used)
      }.not_to change(CustomDocument, :count)
      expect(used.reload).to be_archived
    end

    it "renders the mappings page for a custom document via its mapping key" do
      doc = create(:custom_document, event: event, name: "Hotel Waiver")

      get admin_event_docuseal_template_mappings_path(event, doc.mapping_key)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hotel Waiver Field Mappings")
    end

    it "saves mappings for a custom document under its mapping key" do
      doc = create(:custom_document, event: event)

      patch admin_event_docuseal_template_mappings_path(event, doc.mapping_key), params: {
        mappings: [ { field_name: "Attendee Name", source_key: "participant.full_name", readonly: "1", role: "Attendee" } ]
      }

      config = event.reload.docuseal_field_mappings[doc.mapping_key]
      expect(config["mappings"].first).to include(
        "field_name" => "Attendee Name",
        "source_key" => "participant.full_name",
        "readonly" => true
      )
      expect(doc.field_mapper.has_mappings?).to be true
    end
  end

  describe "admin resend" do
    let(:admin) { User.create!(email: "admin-resend@example.com", name: "Admin", global_role: "global_admin") }
    let(:participant_event) { create(:participant_event, event: event) }
    let(:docuseal) { instance_double(Docuseal::Client, archive_submission: true) }

    before do
      sign_in admin
      allow(Docuseal::Client).to receive(:for).and_return(docuseal)
    end

    def resend(doc)
      post resend_custom_document_admin_event_participant_path(event, participant_event),
        params: { custom_document_id: doc.id }
    end

    it "voids the old submission, resets the consent, and re-enqueues the job" do
      doc = create(:custom_document, event: event)
      consent = create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
        status: :sent, docuseal_envelope_id: "sub-1", docuseal_participant_slug: "abc123",
        failure_reason: "docuseal_error: boom")

      expect { resend(doc) }
        .to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob).with(consent.id)
        .and have_enqueued_mail(ParticipantMailer, :new_document_ready)

      expect(docuseal).to have_received(:archive_submission).with("sub-1")
      expect(consent.reload).to have_attributes(
        status: "pending",
        docuseal_envelope_id: nil,
        docuseal_participant_slug: nil,
        failure_reason: nil
      )
    end

    it "creates the consent when the document was never started" do
      doc = create(:custom_document, event: event)

      expect { resend(doc) }.to change(participant_event.consents, :count).by(1)
      expect(participant_event.consents.last.custom_document).to eq(doc)
    end

    it "re-issues to the guardian without emailing the participant" do
      participant_event.participant.update!(date_of_birth: 15.years.ago)
      create(:guardian_participant_event, participant_event: participant_event)
      doc = create(:custom_document, :guardian_only, event: event)

      expect { resend(doc) }.to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
      # DocuSeal emails the guardian directly; the participant isn't involved.
      expect(enqueued_jobs.map { |job| job[:args].first(2) })
        .not_to include([ "ParticipantMailer", "new_document_ready" ])
      expect(response).to redirect_to(consents_admin_event_participant_path(event, participant_event))
    end

    it "refuses to resend a signed document" do
      doc = create(:custom_document, event: event)
      create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
        status: :signed, signed_at: Time.current, docuseal_envelope_id: "sub-1")

      expect { resend(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
      expect(flash[:alert]).to include("already signed")
      expect(docuseal).not_to have_received(:archive_submission)
    end

    describe "resetting a signed document" do
      def reset(doc)
        delete reset_custom_document_admin_event_participant_path(event, participant_event),
          params: { custom_document_id: doc.id }
      end

      it "discards the signature, re-issues, and reopens the participant" do
        participant_event.update!(status: :complete)
        doc = create(:custom_document, event: event)
        consent = create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
          status: :signed, signed_at: Time.current, participant_signed_at: Time.current,
          docuseal_envelope_id: "sub-1", document_url: "https://docuseal.test/d/abc")

        expect { reset(doc) }
          .to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob).with(consent.id)
          .and have_enqueued_mail(ParticipantMailer, :new_document_ready)

        expect(docuseal).to have_received(:archive_submission).with("sub-1")
        expect(consent.reload).to have_attributes(
          status: "pending",
          signed_at: nil,
          participant_signed_at: nil,
          document_url: nil,
          docuseal_envelope_id: nil
        )
        expect(participant_event.reload.status).to eq("in_progress")
      end

      it "reopens a guardian who had already finished" do
        participant_event.participant.update!(date_of_birth: 15.years.ago)
        gpe = create(:guardian_participant_event, participant_event: participant_event,
          status: :completed, completed_at: Time.current)
        doc = create(:custom_document, :guardian_only, event: event)
        create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
          guardian_participant_event: gpe, status: :signed, signed_at: Time.current,
          guardian_signed_at: Time.current, docuseal_envelope_id: "sub-1")

        reset(doc)

        expect(gpe.reload.status).to eq("in_progress")
      end

      it "refuses to reset a document that isn't signed" do
        doc = create(:custom_document, event: event)
        create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
          status: :sent, docuseal_envelope_id: "sub-1")

        expect { reset(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
        expect(flash[:alert]).to include("use Resend instead")
        expect(docuseal).not_to have_received(:archive_submission)
      end

      it "refuses to reset a physical document" do
        doc = create(:custom_document, :physical, event: event)
        create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
          status: :signed, signed_at: Time.current)

        expect { reset(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
        expect(flash[:alert]).to include("doesn't go through DocuSeal")
      end

      it "shows Reset rather than Resend once the document is signed" do
        doc = create(:custom_document, event: event)
        create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
          status: :signed, signed_at: Time.current)

        get consents_admin_event_participant_path(event, participant_event)

        expect(response.body).to include(reset_custom_document_admin_event_participant_path(event, participant_event))
        expect(response.body).not_to include(resend_custom_document_admin_event_participant_path(event, participant_event))
      end
    end

    it "refuses to resend a physical document" do
      doc = create(:custom_document, :physical, event: event)

      expect { resend(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
      expect(flash[:alert]).to include("signed on paper")
    end

    it "refuses a guardian document when no guardian is on file" do
      participant_event.participant.update!(date_of_birth: 15.years.ago)
      doc = create(:custom_document, :guardian_only, event: event)

      expect { resend(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
      expect(flash[:alert]).to include("needs a guardian")
    end

    it "refuses an optional document the participant hasn't added" do
      doc = create(:custom_document, :optional, event: event)

      expect { resend(doc) }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)
      expect(flash[:alert]).to include("doesn't apply")
    end

    it "still re-issues when DocuSeal can't archive the old submission" do
      doc = create(:custom_document, event: event)
      consent = create(:consent, :custom_document, custom_document: doc, participant_event: participant_event,
        status: :sent, docuseal_envelope_id: "sub-1")
      allow(docuseal).to receive(:archive_submission).and_raise(Docuseal::Error, "gone")

      expect { resend(doc) }.to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob).with(consent.id)
      expect(consent.reload.status).to eq("pending")
    end

    it "shows a Resend button on the consents page" do
      doc = create(:custom_document, event: event)

      get consents_admin_event_participant_path(event, participant_event)

      expect(response.body).to include("Resend")
      expect(response.body).to include(resend_custom_document_admin_event_participant_path(event, participant_event))
      expect(response.body).to include(doc.id)
    end
  end

  describe "participant signing flow" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) { create(:participant_event, participant: participant, event: event, status: :complete) }

    before { sign_in user }

    it "shows applicable documents on the event dashboard" do
      create(:custom_document, event: event, name: "Hotel Waiver")

      get dashboard_event_path(participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Hotel Waiver")
      expect(response.body).to include("Sign now")
    end

    it "hides guardian-only documents from adult participants" do
      participant.update!(date_of_birth: 25.years.ago)
      create(:custom_document, :guardian_only, event: event, name: "Guardian Consent Form")

      get dashboard_event_path(participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Guardian Consent Form")
    end

    it "creates the consent, enqueues the submission job, and shows the preparing state" do
      doc = create(:custom_document, event: event)

      expect {
        get dashboard_sign_document_path(participant_event, doc)
      }.to change(participant_event.consents, :count).by(1)
        .and have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

      consent = participant_event.consents.last
      expect(consent.consent_type).to eq("custom_document")
      expect(consent.custom_document).to eq(doc)
      expect(response.body).to include("Getting this document ready")
    end

    it "embeds the signing form once the submission slug exists" do
      doc = create(:custom_document, event: event)
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, docuseal_envelope_id: "sub-1",
        docuseal_participant_slug: "abc123")

      client = instance_double(Docuseal::Client)
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).and_return(
        "submitters" => [ { "slug" => "abc123", "completed_at" => nil } ]
      )

      get dashboard_sign_document_path(participant_event, doc)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("docuseal-form")
      expect(response.body).to include("abc123")
    end

    it "rejects documents that don't apply to the participant" do
      participant.update!(date_of_birth: 25.years.ago)
      doc = create(:custom_document, :guardian_only, event: event)

      get dashboard_sign_document_path(participant_event, doc)

      expect(response).to redirect_to(dashboard_event_path(participant_event))
    end
  end

  describe "guardian portal signing" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
    let(:token) { gpe.generate_invite_token! }

    it "creates the consent, enqueues the job as guardian, and shows the loading state" do
      doc = create(:custom_document, :guardian_only, event: event)

      expect {
        get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)
      }.to change(participant_event.consents, :count).by(1)
        .and have_enqueued_job(DocusealJobs::CreateCustomDocumentJob).with(anything, "guardian")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Preparing")
    end

    it "embeds the signing form once the guardian slug exists" do
      doc = create(:custom_document, :guardian_only, event: event)
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, docuseal_envelope_id: "sub-1",
        docuseal_guardian_slug: "gslug123", guardian_participant_event: gpe)

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("docuseal-form")
      expect(response.body).to include("gslug123")
    end

    it "redirects instead of spinning when the submission has no guardian slot" do
      doc = create(:custom_document, :dual_signer, event: event)
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, docuseal_envelope_id: "sub-1",
        docuseal_participant_slug: "pslug123")

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
    end

    it "rejects participant-only documents" do
      doc = create(:custom_document, event: event)

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
    end
  end

  describe "completion gating via webhook" do
    let(:secret) { "test-webhook-secret" }
    let(:participant_event) do
      create(:participant_event, event: event, code_of_conduct_accepted_at: Time.current)
        .tap { |pe| pe.participant.update!(date_of_birth: 18.years.ago - 1.month) }
    end

    before { allow(Docuseal::HostConfig).to receive(:webhook_secrets).and_return([ secret ]) }

    def post_completed(consent)
      post docuseal_api_v1_webhooks_path,
        params: { event_type: "submission.completed", data: { metadata: { consent_id: consent.id } } },
        headers: { "X-Webhook-Secret" => secret },
        as: :json
    end

    it "keeps the participant incomplete until custom documents are signed" do
      doc = create(:custom_document, event: event)
      waiver = create(:consent, participant_event: participant_event, status: :sent)
      doc_consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent)

      post_completed(waiver)
      expect(response).to have_http_status(:ok)
      expect(participant_event.reload).not_to be_complete

      post_completed(doc_consent)
      expect(response).to have_http_status(:ok)
      expect(participant_event.reload).to be_complete
    end

    it "still completes on waiver signature when no custom documents exist" do
      waiver = create(:consent, participant_event: participant_event, status: :sent)

      post_completed(waiver)

      expect(participant_event.reload).to be_complete
    end

    it "completes a minor when the freedom waiver is the last signature" do
      freedom_event = create(:event, freedom_waivers_enabled: true)
      minor_pe = create(:participant_event, event: freedom_event, code_of_conduct_accepted_at: Time.current)
      create(:guardian_participant_event, participant_event: minor_pe, status: :completed, completed_at: Time.current)
      create(:consent, :signed, participant_event: minor_pe)
      freedom = create(:consent, :freedom_waiver, participant_event: minor_pe, status: :sent)

      post_completed(freedom)

      expect(minor_pe.reload).to be_complete
    end
  end
end
