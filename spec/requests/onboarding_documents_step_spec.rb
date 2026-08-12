require "rails_helper"

RSpec.describe "Onboarding documents step", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:user) { create(:user) }
  let(:participant) { create(:participant, user: user, email: user.email) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 10)
      .tap { participant.update!(date_of_birth: 18.years.ago - 1.month) }
  end
  let!(:custom_document) { create(:custom_document, event: event, name: "Hotel Waiver") }

  before { sign_in user }

  def documents_path
    onboarding_step_path(step: "documents", event_id: event.id)
  end

  it "appears in the wizard steps before review" do
    get documents_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Sign Your Documents")
    expect(response.body).to include("Event Waiver")
    expect(response.body).to include("Hotel Waiver")
  end

  it "creates the consents and enqueues the submission jobs" do
    expect {
      get documents_path
    }.to change(participant_event.consents, :count).by(2)
      .and have_enqueued_job(DocusealJobs::CreateAdultWaiverJob)
      .and have_enqueued_job(DocusealJobs::CreateCustomDocumentJob)

    expect(response.body).to include("Getting your documents ready")
  end

  it "blocks continuing until every document is participant-signed" do
    get documents_path # creates consents

    patch documents_path
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Please sign all documents")

    participant_event.consents.each { |c| c.update!(status: :signed, signed_at: Time.current) }

    patch documents_path
    expect(response).to redirect_to(onboarding_step_path(step: "review", event_id: event.id))
  end

  it "embeds the first pending document once its slug exists" do
    create(:consent, participant_event: participant_event, status: :sent,
      docuseal_envelope_id: "sub-1", docuseal_participant_slug: "wslug")
    create(:consent, participant_event: participant_event, consent_type: :custom_document,
      custom_document: custom_document, status: :sent, docuseal_envelope_id: "sub-2",
      docuseal_participant_slug: "dslug")

    client = instance_double(Docuseal::Client)
    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(client).to receive(:get_submission) do |id|
      slug = id == "sub-1" ? "wslug" : "dslug"
      { "submitters" => [ { "slug" => slug, "completed_at" => nil } ] }
    end

    get documents_path

    expect(response.body).to include("Now signing: Event Waiver")
    expect(response.body).to include("wslug")
    expect(response.body).not_to include("Now signing: Hotel Waiver")
  end

  it "allows continuing when waiver sending is paused" do
    allow(Setting).to receive(:waiver_sending_paused?).and_return(true)

    patch documents_path

    expect(response).to redirect_to(onboarding_step_path(step: "review", event_id: event.id))
  end

  it "picks up signatures made outside the embed on page load" do
    consent = create(:consent, participant_event: participant_event, status: :sent,
      docuseal_envelope_id: "sub-7", docuseal_participant_slug: "wslug")

    client = instance_double(Docuseal::Client)
    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(client).to receive(:get_submission).with("sub-7").and_return(
      "submitters" => [ { "slug" => "wslug", "completed_at" => Time.current.iso8601 } ]
    )

    get documents_path

    expect(consent.reload).to be_signed
    expect(response.body).not_to include("Now signing: Event Waiver")
  end

  describe "submitting as a minor" do
    it "enqueues the guardian invitation at submit" do
      participant.update!(date_of_birth: 16.years.ago)
      gpe = create(:guardian_participant_event, participant_event: participant_event)
      create(:consent, :signed, participant_event: participant_event)
      participant_event.emergency_contacts.create!(name: "Erin", phone: "+14155550100")

      expect {
        post complete_onboarding_path(event_id: event.id), params: {
          code_of_conduct_accepted: "1", code_of_conduct_signature: "Milo Minorson"
        }
      }.to have_enqueued_job(ActionMailer::MailDeliveryJob)
        .with("GuardianMailer", "invitation", "deliver_now", args: [ { guardian_participant_event: gpe } ])

      expect(response).to redirect_to(dashboard_path)
      expect(participant_event.reload).to be_awaiting_guardian
    end
  end

  describe "POST document_signed" do
    it "syncs signature state from the DocuSeal API" do
      consent = create(:consent, participant_event: participant_event, status: :sent,
        docuseal_envelope_id: "sub-9", docuseal_participant_slug: "pslug")

      client = instance_double(Docuseal::Client)
      allow(Docuseal::Client).to receive(:for).and_return(client)
      allow(client).to receive(:get_submission).with("sub-9").and_return(
        "submitters" => [ { "slug" => "pslug", "completed_at" => Time.current.iso8601 } ]
      )

      post onboarding_document_signed_path(consent_id: consent.id, event_id: event.id)

      expect(response).to redirect_to(documents_path)
      consent.reload
      expect(consent.participant_signed_at).to be_present
      expect(consent).to be_signed
    end

    it "resets a failed consent for retry" do
      consent = create(:consent, participant_event: participant_event, status: :failed,
        failure_reason: "docuseal_error: boom", docuseal_envelope_id: "sub-9")

      post onboarding_document_signed_path(consent_id: consent.id, event_id: event.id, retry: 1)

      consent.reload
      expect(consent).to be_pending
      expect(consent.docuseal_envelope_id).to be_nil
    end
  end
end
