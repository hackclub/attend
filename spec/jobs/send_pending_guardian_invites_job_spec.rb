require "rails_helper"

RSpec.describe SendPendingGuardianInvitesJob do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }

  def submitted_minor_pe
    participant = create(:participant, date_of_birth: 16.years.ago)
    create(:participant_event, event: event, participant: participant,
      status: :awaiting_guardian, code_of_conduct_accepted_at: 1.day.ago)
  end

  def submitted_adult_pe
    participant = create(:participant, date_of_birth: 18.years.ago - 1.month)
    create(:participant_event, event: event, participant: participant,
      status: :in_progress, code_of_conduct_accepted_at: 1.day.ago)
  end

  describe "waiver backfill" do
    it "creates and triggers waivers for minors who submitted while locked" do
      pe = submitted_minor_pe
      create(:guardian_participant_event, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.to change { pe.consents.waiver.count }.by(1)
        .and have_enqueued_job(DocusealJobs::CreateMinorWaiverJob)
    end

    it "creates and triggers waivers for adults who submitted while locked (stuck in_progress)" do
      pe = submitted_adult_pe

      expect {
        described_class.perform_now(event.id)
      }.to change { pe.consents.waiver.count }.by(1)
        .and have_enqueued_job(DocusealJobs::CreateAdultWaiverJob)
    end

    it "creates the waiver even when unrelated consents already exist" do
      pe = submitted_minor_pe
      create(:guardian_participant_event, participant_event: pe)
      create(:consent, :custom_document, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.to change { pe.consents.waiver.count }.by(1)
    end

    it "re-triggers a waiver whose DocuSeal submission never materialised" do
      pe = submitted_adult_pe
      create(:consent, participant_event: pe, status: :pending, docuseal_participant_slug: nil)

      expect {
        described_class.perform_now(event.id)
      }.to have_enqueued_job(DocusealJobs::CreateAdultWaiverJob)
    end

    it "ignores participants who have not submitted onboarding" do
      participant = create(:participant, date_of_birth: 18.years.ago - 1.month)
      create(:participant_event, event: event, participant: participant, status: :in_progress)

      expect {
        described_class.perform_now(event.id)
      }.not_to change(Consent, :count)
    end

    it "leaves waivers that already have a submission alone" do
      pe = submitted_adult_pe
      create(:consent, participant_event: pe, status: :sent,
        docuseal_envelope_id: "sub-1", docuseal_participant_slug: "pslug")

      expect {
        described_class.perform_now(event.id)
      }.not_to have_enqueued_job(DocusealJobs::CreateAdultWaiverJob)
    end
  end

  describe "guardian invites" do
    def invitation_for(gpe)
      have_enqueued_job(ActionMailer::Base.delivery_job)
        .with("GuardianMailer", "invitation", "deliver_now", args: [ { guardian_participant_event: gpe } ])
    end

    it "invites guardians who were never sent one" do
      pe = submitted_minor_pe
      gpe = create(:guardian_participant_event, :never_sent, participant_event: pe)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.to invitation_for(gpe)
    end

    it "re-invites guardians whose invite expired before they opened the portal" do
      pe = submitted_minor_pe
      gpe = create(:guardian_participant_event, participant_event: pe, invite_token_sent_at: 8.days.ago)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.to invitation_for(gpe)
    end

    # Opening the portal used to exempt a guardian from re-invites entirely,
    # which stranded anyone who opened the link once and then let it lapse.
    it "re-invites guardians who opened the portal but let the link lapse" do
      pe = submitted_minor_pe
      gpe = create(:guardian_participant_event, participant_event: pe,
        invite_token_sent_at: 30.days.ago, invite_last_used_at: 8.days.ago,
        accepted_at: 20.days.ago, status: :in_progress)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.to invitation_for(gpe)
    end

    it "does not re-invite guardians whose link is still live from recent use" do
      pe = submitted_minor_pe
      create(:guardian_participant_event, participant_event: pe,
        invite_token_sent_at: 30.days.ago, invite_last_used_at: 1.day.ago,
        accepted_at: 20.days.ago, status: :in_progress)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.not_to have_enqueued_job(ActionMailer::Base.delivery_job)
    end

    it "skips guardians whose email is known-undeliverable" do
      pe = submitted_minor_pe
      gpe = create(:guardian_participant_event, :never_sent, participant_event: pe)
      gpe.guardian.update!(email_undeliverable_at: Time.current)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.not_to have_enqueued_job(ActionMailer::Base.delivery_job)
    end

    it "does not re-invite unopened invites still inside their validity window" do
      pe = submitted_minor_pe
      create(:guardian_participant_event, participant_event: pe, invite_token_sent_at: 2.days.ago)
      create(:consent, :signed, participant_event: pe)

      expect {
        described_class.perform_now(event.id)
      }.not_to have_enqueued_job(ActionMailer::Base.delivery_job)
    end
  end
end
