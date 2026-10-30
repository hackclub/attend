require "rails_helper"

# The embedded DocuSeal form's "completed" event used to be the only thing
# moving a guardian off a signing page. When it didn't reach us (signed in the
# new-tab fallback, a dropped postMessage), or they opened the page again
# before the webhook landed, they sat on DocuSeal's "Document has been
# signed!" screen with nothing to press. The participant's documents step
# already polled for this; the guardian's signing pages now do too.
RSpec.describe "Guardian portal signing status", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event, freedom_waivers_enabled: false) }
  let(:participant) { create(:participant, date_of_birth: 15.years.ago) }
  let(:participant_event) do
    create(:participant_event, participant: participant, event: event,
      status: :awaiting_guardian, code_of_conduct_accepted_at: Time.current)
  end
  let!(:gpe) do
    create(:guardian_participant_event, :details_reviewed, participant_event: participant_event, status: :in_progress,
      accepted_at: Time.current).tap do |g|
      g.guardian.update!(legal_first_name: "Pat", legal_last_name: "Guardian", phone: "+14155550150")
      g.emergency_contacts.create!(name: "Pat Guardian", phone: "+14155550150", relationship: "Parent")
    end
  end
  let(:token) { gpe.generate_invite_token! }
  let!(:waiver) do
    create(:consent, participant_event: participant_event, consent_type: :waiver, status: :sent,
      docuseal_envelope_id: "waiver-1", docuseal_participant_slug: "pslug", docuseal_guardian_slug: "gslug",
      participant_signed_at: Time.current, pending_on: "guardian", guardian_participant_event: gpe)
  end
  let(:client) { instance_double(Docuseal::Client) }

  def docuseal_reports(submission_id, guardian_completed:)
    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(client).to receive(:get_submission).with(submission_id).and_return(
      "submitters" => [
        { "slug" => "pslug", "completed_at" => 1.hour.ago.iso8601 },
        { "slug" => "gslug", "completed_at" => (Time.current.iso8601 if guardian_completed) }
      ]
    )
  end

  describe "GET waiver" do
    it "moves a guardian who already signed on instead of showing the form again" do
      waiver.update!(status: :signed, signed_at: Time.current, guardian_signed_at: Time.current, pending_on: nil)

      expect(Docuseal::Client).not_to receive(:for)
      get guardian_portal_waiver_path(token: token)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(gpe.reload).to be_completed
    end

    it "pulls a signature the webhook hasn't delivered yet and moves them on" do
      docuseal_reports("waiver-1", guardian_completed: true)

      get guardian_portal_waiver_path(token: token)

      expect(response).to redirect_to(guardian_portal_confirmed_path(token: token))
      expect(waiver.reload).to be_signed
      expect(gpe.reload).to be_completed
    end

    it "shows the form, polling for the signature, while the guardian hasn't signed" do
      docuseal_reports("waiver-1", guardian_completed: false)

      get guardian_portal_waiver_path(token: token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("docuseal-form")
      expect(response.body).to include(guardian_portal_signing_status_path(token: token, consent_id: waiver.id))
    end

    it "still shows the form when DocuSeal can't be reached" do
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).and_raise(Faraday::TimeoutError)

      get guardian_portal_waiver_path(token: token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("docuseal-form")
    end
  end

  describe "GET signing_status" do
    def status_path(consent = waiver)
      guardian_portal_signing_status_path(token: token, consent_id: consent.id)
    end

    def signed_ids
      response.parsed_body["signed_consent_ids"]
    end

    # The throttle is what keeps a few-second poll from hammering DocuSeal, so
    # give it a cache that remembers (test runs on :null_store).
    around do |example|
      cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = cache
    end

    it "reports a signature the webhook recorded, without calling DocuSeal" do
      # The guardian signed first; the waiver isn't fully signed, but their
      # part is done.
      waiver.update!(participant_signed_at: nil, guardian_signed_at: Time.current, pending_on: nil)

      expect(Docuseal::Client).not_to receive(:for)
      get status_path

      expect(signed_ids).to eq([ waiver.id.to_s ])
    end

    it "pulls an outstanding signature from the DocuSeal API, throttled" do
      docuseal_reports("waiver-1", guardian_completed: false)

      get status_path
      get status_path # inside the throttle window, so no second API call
      expect(client).to have_received(:get_submission).once
      expect(signed_ids).to eq([])

      docuseal_reports("waiver-1", guardian_completed: true)
      travel(GuardianPortalController::DOCUSEAL_POLL_THROTTLE + 1.second) { get status_path }

      expect(signed_ids).to eq([ waiver.id.to_s ])
      expect(waiver.reload).to be_signed
    end

    it "doesn't answer for another registration's consent" do
      other = create(:consent, consent_type: :waiver, status: :sent, docuseal_envelope_id: "other-1")

      expect(Docuseal::Client).not_to receive(:for)
      get status_path(other)

      # ApplicationController turns RecordNotFound into a redirect.
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET custom_document" do
    let(:doc) { create(:custom_document, :guardian_only, event: event) }
    let!(:consent) do
      create(:consent, participant_event: participant_event, consent_type: :custom_document,
        custom_document: doc, status: :sent, docuseal_envelope_id: "doc-1",
        docuseal_guardian_slug: "gslug", guardian_participant_event: gpe)
    end

    it "shows a document the webhook hasn't caught up on as signed, not the form" do
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).with("doc-1").and_return(
        "submitters" => [ { "slug" => "gslug", "completed_at" => Time.current.iso8601 } ]
      )

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This document is signed")
      expect(response.body).not_to include("docuseal-form")
    end

    it "polls for the signature while the form is up" do
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).with("doc-1").and_return(
        "submitters" => [ { "slug" => "gslug", "completed_at" => nil } ]
      )

      get guardian_portal_custom_document_path(token: token, custom_document_id: doc.id)

      expect(response.body).to include("docuseal-form")
      expect(response.body).to include(guardian_portal_signing_status_path(token: token, consent_id: consent.id))
    end
  end
end
