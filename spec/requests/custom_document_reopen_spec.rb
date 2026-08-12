require "rails_helper"

RSpec.describe "Custom document reopening", type: :request do
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:admin) { User.create!(email: "admin-reopen@example.com", name: "Admin", global_role: "global_admin") }

  before { sign_in admin }

  # A participant who finished onboarding before the new document existed.
  def create_complete_participant(event, date_of_birth: 18.years.ago - 1.month)
    participant = create(:participant, date_of_birth: date_of_birth)
    participant_event = create(:participant_event, participant: participant, event: event,
      status: :complete, code_of_conduct_accepted_at: Time.current)
    create(:consent, :signed, participant_event: participant_event)
    participant_event
  end

  def add_document(event, attrs = {})
    post admin_event_custom_documents_path(event), params: {
      custom_document: {
        name: "Hotel Waiver", docuseal_template_id: "1234", signer_type: "participant"
      }.merge(attrs)
    }
  end

  describe "adding a document after completion" do
    it "regresses complete participants to in_progress, paper-trailed, and emails them" do
      participant_event = create_complete_participant(event)

      expect {
        add_document(event)
        perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)
      }.to change { participant_event.reload.status }.from("complete").to("in_progress")
        .and change { participant_event.versions.count }.by(1)
        .and have_enqueued_mail(ParticipantMailer, :new_document_ready)
    end

    it "skips adults for minor_and_guardian documents" do
      participant_event = create_complete_participant(event)

      expect {
        add_document(event, signer_type: "minor_and_guardian")
        perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)
      }.not_to have_enqueued_mail(ParticipantMailer, :new_document_ready)

      expect(participant_event.reload.status).to eq("complete")
    end

    it "regresses complete minors for minor_and_guardian documents" do
      participant_event = create_complete_participant(event, date_of_birth: 16.years.ago)

      add_document(event, signer_type: "minor_and_guardian")
      perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)

      expect(participant_event.reload.status).to eq("in_progress")
    end

    it "leaves participants who are not complete alone" do
      participant_event = create(:participant_event, event: event, status: :in_progress)

      expect {
        add_document(event)
        perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)
      }.not_to have_enqueued_mail(ParticipantMailer, :new_document_ready)

      expect(participant_event.reload.status).to eq("in_progress")
    end
  end

  describe "while guardian invites are locked" do
    let(:event) { create(:event, guardian_invites_locked: true) }

    it "defers the regress and email until unlock" do
      participant_event = create_complete_participant(event)

      expect {
        add_document(event)
      }.not_to have_enqueued_job(ReopenParticipantsForCustomDocumentsJob)
      expect(participant_event.reload.status).to eq("complete")

      expect {
        event.update!(guardian_invites_locked: false)
      }.to have_enqueued_job(ReopenParticipantsForCustomDocumentsJob).with(event.id)

      expect {
        perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)
      }.to change { participant_event.reload.status }.from("complete").to("in_progress")
        .and have_enqueued_mail(ParticipantMailer, :new_document_ready)
    end

    it "no-ops when the event was re-locked before the job ran" do
      participant_event = create_complete_participant(event)
      event.custom_documents.create!(name: "Hotel Waiver", docuseal_template_id: "1234", signer_type: "participant")

      expect {
        ReopenParticipantsForCustomDocumentsJob.perform_now(event.id)
      }.not_to have_enqueued_mail(ParticipantMailer, :new_document_ready)

      expect(participant_event.reload.status).to eq("complete")
    end
  end

  describe "re-completion after signing" do
    it "marks the participant complete again once the document is signed" do
      participant_event = create_complete_participant(event)
      document = create(:custom_document, :physical, event: event)
      perform_enqueued_jobs(only: ReopenParticipantsForCustomDocumentsJob)
      expect(participant_event.reload.status).to eq("in_progress")

      consent = create(:consent, :custom_document, participant_event: participant_event, custom_document: document)
      consent.physical_uploads.attach(io: StringIO.new("photo"), filename: "signed.jpg", content_type: "image/jpeg")
      consent.mark_physical_uploaded_by_participant!

      expect(participant_event.reload.status).to eq("complete")
    end
  end
end
