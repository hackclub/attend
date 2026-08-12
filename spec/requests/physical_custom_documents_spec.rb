require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_have_enqueued_job, :have_enqueued_job

RSpec.describe "Physical custom documents", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  # Freedom waivers default on; disable them so custom documents are the only
  # thing gating minors in these specs.
  let(:event) { create(:event, freedom_waivers_enabled: false) }

  # Real JPEG magic bytes — uploads are sniffed, so fake bytes get rejected.
  def jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01#{"\x00" * 8}\xFF\xD9".b
  end

  def photo_upload
    Rack::Test::UploadedFile.new(
      StringIO.new(jpeg_bytes), "image/jpeg", original_filename: "signed.jpg"
    )
  end

  def pdf_upload(pages: 1)
    pdf = Prawn::Document.new { |p| (pages - 1).times { p.start_new_page } }
    Rack::Test::UploadedFile.new(
      StringIO.new(pdf.render), "application/pdf", original_filename: "form.pdf"
    )
  end

  describe "admin management" do
    let(:admin) { User.create!(email: "admin-physical@example.com", name: "Admin", global_role: "global_admin") }

    before { sign_in admin }

    it "creates a physical document with a PDF and no template id" do
      expect {
        post admin_event_custom_documents_path(event), params: {
          custom_document: {
            name: "Immigration Form",
            document_kind: "physical",
            description: "Required for minors travelling alone",
            signer_type: "minor_and_guardian",
            template_pdf: pdf_upload(pages: 2)
          }
        }
      }.to change(event.custom_documents, :count).by(1)

      doc = event.custom_documents.last
      expect(doc).to be_physical
      expect(doc.signer_type).to eq("minor_and_guardian")
      expect(doc.description).to eq("Required for minors travelling alone")
      expect(doc.template_pdf).to be_attached
      expect(doc.template_page_count).to eq(2)
    end

    it "rejects a template that isn't really a PDF, whatever it claims" do
      expect {
        post admin_event_custom_documents_path(event), params: {
          custom_document: {
            name: "Immigration Form",
            document_kind: "physical",
            signer_type: "participant",
            template_pdf: fixture_file_upload("evidence.txt", "application/pdf")
          }
        }
      }.not_to change(event.custom_documents, :count)

      expect(flash[:alert]).to include("must be a valid PDF")
    end

    it "rejects a physical document without a PDF" do
      expect {
        post admin_event_custom_documents_path(event), params: {
          custom_document: { name: "Immigration Form", document_kind: "physical", signer_type: "participant" }
        }
      }.not_to change(event.custom_documents, :count)

      expect(flash[:alert]).to include("Template pdf")
    end
  end

  describe "participant upload from the dashboard" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) { create(:participant_event, participant: participant, event: event, status: :complete) }

    before { sign_in user }

    it "shows the download/sign/upload flow without enqueuing DocuSeal jobs" do
      doc = create(:custom_document, :physical, event: event, name: "Immigration Form")

      expect {
        get dashboard_sign_document_path(participant_event, doc)
      }.to change(participant_event.consents, :count).by(1)
        .and not_have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Download and print the document")
      expect(response.body).to include("Upload photo(s) of the signed document")
    end

    it "marks a dual-signer minor upload as awaiting guardian confirmation" do
      doc = create(:custom_document, :physical, :dual_signer, event: event, name: "Immigration Form")
      create(:guardian_participant_event, participant_event: participant_event)

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent.physical_uploads).to be_attached
      expect(consent.participant_signed_at).to be_present
      expect(consent).not_to be_signed
      expect(consent.pending_on).to eq("guardian")
    end

    it "completes an adult's upload immediately" do
      participant.update!(date_of_birth: 25.years.ago)
      doc = create(:custom_document, :physical, :dual_signer, event: event)

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent).to be_signed
      expect(consent.signed_at).to be_present
    end

    it "leaves an already-signed consent untouched on re-upload" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :signed, signed_at: 2.days.ago)
      original_signed_at = consent.reload.signed_at

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      expect(flash[:notice]).to include("already confirmed")
      expect(consent.reload).to be_signed
      expect(consent.signed_at).to eq(original_signed_at)
      expect(consent.physical_uploads).not_to be_attached
    end

    it "rejects an upload posted against another user's participant event" do
      doc = create(:custom_document, :physical, event: event)
      other_user = create(:user)
      create(:participant, user: other_user)
      sign_in other_user

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      expect(response).to redirect_to(root_path)
      expect(participant_event.consents.find_by(custom_document: doc)).to be_nil
    end

    it "does not offer archived physical documents for signing" do
      doc = create(:custom_document, :physical, :archived, event: event)

      expect {
        get dashboard_sign_document_path(participant_event, doc)
      }.not_to change(participant_event.consents, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("could not be found")
    end

    it "rejects uploads with disallowed content types" do
      doc = create(:custom_document, :physical, event: event)

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ fixture_file_upload("evidence.txt", "text/plain") ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent.physical_uploads).not_to be_attached
      expect(flash[:alert]).to include("photos")
    end

    it "rejects an empty upload" do
      doc = create(:custom_document, :physical, event: event)

      post dashboard_upload_physical_document_path(participant_event, doc), params: {}

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent.physical_uploads).not_to be_attached
      expect(flash[:alert]).to be_present
    end

    it "rejects a file whose bytes don't match its declared image type" do
      doc = create(:custom_document, :physical, event: event)
      fake_photo = Rack::Test::UploadedFile.new(
        StringIO.new("just some text pretending to be a photo"), "image/jpeg", original_filename: "signed.jpg"
      )

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ fake_photo ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent.physical_uploads).not_to be_attached
      expect(flash[:alert]).to include("photos")
    end

    it "rejects a corrupt PDF scan" do
      doc = create(:custom_document, :physical, event: event)
      corrupt_pdf = Rack::Test::UploadedFile.new(
        StringIO.new("%PDF-1.4 not actually parseable"), "application/pdf", original_filename: "scan.pdf"
      )

      post dashboard_upload_physical_document_path(participant_event, doc), params: {
        consent: { physical_uploads: [ corrupt_pdf ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent.physical_uploads).not_to be_attached
      expect(flash[:alert]).to include("corrupt")
    end

    describe "capping uploads at the template's page count" do
      let!(:doc) { create(:custom_document, :physical, :dual_signer, event: event, pages: 2) }

      before { create(:guardian_participant_event, participant_event: participant_event) }

      it "rejects more files than the template has pages in one request" do
        post dashboard_upload_physical_document_path(participant_event, doc), params: {
          consent: { physical_uploads: [ photo_upload, photo_upload, photo_upload ] }
        }

        consent = participant_event.consents.find_by(custom_document: doc)
        expect(consent.physical_uploads).not_to be_attached
        expect(flash[:alert]).to include("at most 2 files for this 2-page document")
      end

      it "counts already-attached uploads against the cap" do
        post dashboard_upload_physical_document_path(participant_event, doc), params: {
          consent: { physical_uploads: [ photo_upload, photo_upload ] }
        }

        consent = participant_event.consents.find_by(custom_document: doc)
        expect(consent.physical_uploads.count).to eq(2)

        post dashboard_upload_physical_document_path(participant_event, doc), params: {
          consent: { physical_uploads: [ photo_upload ] }
        }

        expect(flash[:alert]).to include("at most 2 files")
        expect(consent.reload.physical_uploads.count).to eq(2)
      end
    end

    describe "removing an upload" do
      let!(:doc) { create(:custom_document, :physical, :dual_signer, event: event) }

      before { create(:guardian_participant_event, participant_event: participant_event) }

      it "purges the upload and resets the consent to pending when it was the last one" do
        post dashboard_upload_physical_document_path(participant_event, doc), params: {
          consent: { physical_uploads: [ photo_upload ] }
        }
        consent = participant_event.consents.find_by(custom_document: doc)
        expect(consent.pending_on).to eq("guardian")
        upload = consent.physical_uploads.attachments.first

        get dashboard_sign_document_path(participant_event, doc)
        expect(response.body).to include("Remove")
        expect(response.body).to include("1 of 1 file uploaded")

        delete dashboard_remove_physical_upload_path(participant_event, doc, upload_id: upload.id)

        expect(flash[:notice]).to include("removed")
        consent.reload
        expect(consent.physical_uploads).not_to be_attached
        expect(consent.status).to eq("pending")
        expect(consent.participant_signed_at).to be_nil
        expect(consent.pending_on).to be_nil
      end

      it "refuses removal once the consent is signed" do
        consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
          custom_document: doc, status: :signed, signed_at: Time.current)
        consent.physical_uploads.attach(io: StringIO.new(jpeg_bytes), filename: "signed.jpg", content_type: "image/jpeg")
        upload = consent.physical_uploads.attachments.first

        delete dashboard_remove_physical_upload_path(participant_event, doc, upload_id: upload.id)

        expect(flash[:alert]).to include("no longer be removed")
        expect(consent.reload.physical_uploads).to be_attached
      end

      it "rejects a removal posted against another user's participant event" do
        consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
          custom_document: doc, status: :sent, participant_signed_at: Time.current)
        consent.physical_uploads.attach(io: StringIO.new(jpeg_bytes), filename: "signed.jpg", content_type: "image/jpeg")
        upload = consent.physical_uploads.attachments.first

        other_user = create(:user)
        create(:participant, user: other_user)
        sign_in other_user

        delete dashboard_remove_physical_upload_path(participant_event, doc, upload_id: upload.id)

        expect(response).to redirect_to(root_path)
        expect(consent.reload.physical_uploads).to be_attached
      end
    end
  end

  describe "guardian review and confirmation" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }
    let(:token) { gpe.generate_invite_token! }

    it "shows awaiting-upload state before the participant uploads" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)

      expect {
        get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)
      }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("needs to upload the signed document first")
    end

    it "shows the uploaded photo and confirms it via the checkbox" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current, pending_on: "guardian")
      consent.physical_uploads.attach(io: StringIO.new("fake-jpeg-bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)
      expect(response.body).to include("review it below and confirm")

      post guardian_portal_verify_physical_document_path(token: token, custom_document_id: doc.id),
        params: { confirm_accurate: "1" }

      expect(consent.reload).to be_signed
      expect(consent.guardian_signed_at).to be_present
    end

    it "refuses to confirm without the checkbox" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current)
      consent.physical_uploads.attach(io: StringIO.new("fake-jpeg-bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      post guardian_portal_verify_physical_document_path(token: token, custom_document_id: doc.id)

      expect(consent.reload).not_to be_signed
      expect(flash[:alert]).to include("tick the box")
    end

    it "renders the download-and-upload UI for a guardian-only physical document" do
      doc = create(:custom_document, :physical, :guardian_only, event: event)

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Download and print")
    end

    it "shows the awaiting-participant state for an electronic minor_and_guardian document" do
      doc = create(:custom_document, :minors_only, event: event)
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, docuseal_envelope_id: "env-1",
        docuseal_participant_slug: "part-slug", docuseal_guardian_slug: "guard-slug")

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("needs to sign first")
      expect(response.body).not_to include("docuseal-form")
    end

    it "lets a guardian upload a guardian-only physical document, completing it" do
      doc = create(:custom_document, :physical, :guardian_only, event: event)

      post guardian_portal_upload_physical_document_path(token: token, custom_document_id: doc.id), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      consent = participant_event.consents.find_by(custom_document: doc)
      expect(consent).to be_signed
      expect(consent.guardian_signed_at).to be_present
      expect(consent.guardian_participant_event).to eq(gpe)
    end

    it "lets a guardian remove their own upload before the document is confirmed" do
      doc = create(:custom_document, :physical, :guardian_only, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, guardian_participant_event: gpe)
      consent.physical_uploads.attach(io: StringIO.new(jpeg_bytes), filename: "signed.jpg", content_type: "image/jpeg")
      upload = consent.physical_uploads.attachments.first

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)
      expect(response.body).to include("Remove")

      delete guardian_portal_remove_physical_upload_path(token: token, custom_document_id: doc.id, upload_id: upload.id)

      expect(flash[:notice]).to include("removed")
      consent.reload
      expect(consent.physical_uploads).not_to be_attached
      expect(consent.status).to eq("pending")
    end

    it "serves HEIC uploads through a JPEG variant on the review page" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current, pending_on: "guardian")
      # Direct attach skips the controller's byte sniffing, so a stand-in body is fine.
      consent.physical_uploads.attach(io: StringIO.new("fake-heic-bytes"), filename: "signed.heic", content_type: "image/heic")

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("/rails/active_storage/representations/")
    end

    it "completes the participant when guardian confirmation is the last blocker" do
      participant_event.update!(code_of_conduct_accepted_at: Time.current)
      gpe.update!(status: :completed, completed_at: Time.current)
      create(:consent, :signed, participant_event: participant_event) # waiver

      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current, pending_on: "guardian")
      consent.physical_uploads.attach(io: StringIO.new("fake-jpeg-bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      post guardian_portal_verify_physical_document_path(token: token, custom_document_id: doc.id),
        params: { confirm_accurate: "1" }

      expect(participant_event.reload).to be_complete
    end
  end

  describe "guardian portal completion gating" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) do
      create(:guardian_participant_event, participant_event: participant_event).tap do |g|
        g.guardian.update!(legal_first_name: "Pat", legal_last_name: "Guardian", phone: "+15555550100")
        g.emergency_contacts.create!(name: "Pat Guardian", phone: "+15555550100", relationship: "Parent")
      end
    end
    let(:token) { gpe.generate_invite_token! }

    before do
      # Waiver + freedom waiver out of the way so custom documents are the only blocker.
      create(:consent, :signed, participant_event: participant_event, guardian_signed_at: Time.current)
    end

    it "blocks completion while an uploaded physical document awaits confirmation" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current)
      consent.physical_uploads.attach(io: StringIO.new("fake-jpeg-bytes"), filename: "signed.jpg", content_type: "image/jpeg")

      post guardian_portal_complete_path(token: token)

      expect(gpe.reload).not_to be_completed
    end

    it "does not block completion when the participant hasn't uploaded yet" do
      create(:custom_document, :physical, :dual_signer, event: event)

      post guardian_portal_complete_path(token: token)

      expect(gpe.reload).to be_completed
    end

    it "blocks completion on guardian-only physical documents until uploaded" do
      doc = create(:custom_document, :physical, :guardian_only, event: event)

      post guardian_portal_complete_path(token: token)
      expect(gpe.reload).not_to be_completed

      post guardian_portal_upload_physical_document_path(token: token, custom_document_id: doc.id), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }
      post guardian_portal_complete_path(token: token)
      expect(gpe.reload).to be_completed
    end
  end

  describe "guardian portal overview messaging" do
    let(:participant_event) { create(:participant_event, event: event) }
    let(:gpe) do
      create(:guardian_participant_event, participant_event: participant_event, relationship: "Parent").tap do |g|
        g.guardian.update!(
          legal_first_name: "Pat", legal_last_name: "Guardian", phone: "+15555550100",
          address_line_1: "1 Main St", city: "Burlington", state: "VT", postal_code: "05401", country: "US"
        )
        g.emergency_contacts.create!(name: "Pat Guardian", phone: "+15555550100", relationship: "Parent")
        g.update!(participant_info_reviewed_at: Time.current)
      end
    end
    let(:token) { gpe.generate_invite_token! }

    before do
      create(:consent, :signed, participant_event: participant_event, guardian_signed_at: Time.current)
    end

    it "says the participant still needs to upload instead of claiming everything is done" do
      create(:custom_document, :physical, :dual_signer, event: event, name: "Entry Authorization")

      get guardian_portal_path(token: token)

      expect(response.body).to include("Your Part Is Done")
      expect(response.body).to include("still needs to upload")
      expect(response.body).to include("Entry Authorization")
      expect(response.body).not_to include("All Steps Complete!")
    end

    it "claims all steps complete when no physical document is awaiting the participant" do
      get guardian_portal_path(token: token)

      expect(response.body).to include("All Steps Complete!")
      expect(response.body).not_to include("still needs to upload")
    end

    it "drops the note once the document is uploaded and awaiting guardian confirmation" do
      doc = create(:custom_document, :physical, :dual_signer, event: event, name: "Entry Authorization")
      consent = create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, participant_signed_at: Time.current)
      consent.physical_uploads.attach(io: StringIO.new(jpeg_bytes), filename: "signed.jpg", content_type: "image/jpeg")

      get guardian_portal_path(token: token)

      # The doc now blocks the consents step outright, so the overview drops
      # back to "complete all steps" rather than the awaiting-participant note.
      expect(response.body).not_to include("still needs to upload")
      expect(response.body).not_to include("All Steps Complete!")
    end
  end

  describe "onboarding documents step" do
    let(:user) { create(:user) }
    let(:participant) { create(:participant, user: user) }
    let!(:participant_event) do
      create(:participant_event, participant: participant, event: event,
        onboarding_step: 10, status: :in_progress)
    end

    before do
      sign_in user
      create(:guardian_participant_event, participant_event: participant_event)
      # An already-signed waiver so physical docs are the only pending item.
      create(:consent, :signed, participant_event: participant_event)
    end

    it "lists the physical document with an upload section instead of an embed" do
      create(:custom_document, :physical, :dual_signer, event: event, name: "Immigration Form")

      expect {
        get onboarding_step_path(step: "documents", event_id: event.id)
      }.not_to have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Immigration Form")
      expect(response.body).to include("Upload below")
      expect(response.body).to include("Download and print the document")
      expect(response.body).not_to include("Getting your documents ready to sign")
    end

    it "accepts the upload and marks the participant portion complete" do
      doc = create(:custom_document, :physical, :dual_signer, event: event)
      get onboarding_step_path(step: "documents", event_id: event.id) # creates the consent
      consent = participant_event.consents.find_by(custom_document: doc)

      post onboarding_physical_document_upload_path(consent_id: consent.id, event_id: event.id), params: {
        consent: { physical_uploads: [ photo_upload ] }
      }

      expect(consent.reload.participant_signed_at).to be_present

      get onboarding_step_path(step: "documents", event_id: event.id)
      expect(response.body).to include("Uploaded")

      patch onboarding_step_path(step: "documents", event_id: event.id)
      expect(response).to redirect_to(onboarding_step_path(step: "review", event_id: event.id))
    end
  end
end
