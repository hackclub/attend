require "rails_helper"

RSpec.describe SendHeldOnboardingInvitesJob do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }

  # The mailer's keyword arguments, as serialised on the enqueued delivery job.
  def enqueued_mail_params
    enqueued_jobs
      .select { |job| job["job_class"] == "MailDeliveryJob" }
      .map { |job| job[:args].last["args"].first }
  end

  it "emails every held invitation and leaves sent ones alone" do
    held_a = create(:invitation, event: event, email: "a@example.com", sent_at: nil)
    held_b = create(:invitation, event: event, email: "b@example.com", sent_at: nil)
    create(:invitation, event: event, email: "already@example.com", sent_at: 1.day.ago)

    expect {
      described_class.perform_now(event.id)
    }.to have_enqueued_mail(ParticipantMailer, :invitation).twice

    expect(enqueued_mail_params.map { |params| params["email"] }).to contain_exactly(held_a.email, held_b.email)
  end

  it "passes the imported participant so the greeting uses their name" do
    participant = create(:participant, email: "imported@example.com", preferred_name: "Sam")
    create(:invitation, event: event, email: participant.email, sent_at: nil)

    described_class.perform_now(event.id)

    expect(enqueued_mail_params.sole.dig("participant", "_aj_globalid")).to eq(participant.to_global_id.to_s)
  end

  it "skips undeliverable and banned addresses" do
    bouncing = create(:participant, email: "bounce@example.com", email_undeliverable_at: 1.day.ago)
    create(:invitation, event: event, email: bouncing.email, sent_at: nil)
    banned = create(:invitation, event: event, email: "later-banned@example.com", sent_at: nil)
    create(:ban, email: banned.email)
    create(:invitation, event: event, email: "fine@example.com", sent_at: nil)

    described_class.perform_now(event.id)

    expect(enqueued_mail_params.map { |params| params["email"] }).to eq([ "fine@example.com" ])
  end

  it "no-ops when the event was put back on hold before the job ran" do
    create(:invitation, event: event, email: "held@example.com", sent_at: nil)
    event.update!(onboarding_invites_held: true)

    expect {
      described_class.perform_now(event.id)
    }.not_to have_enqueued_mail(ParticipantMailer, :invitation)
  end

  it "marks the invitation sent once the mail goes out" do
    invitation = create(:invitation, event: event, email: "stamp@example.com", sent_at: nil)

    perform_enqueued_jobs { described_class.perform_now(event.id) }

    expect(invitation.reload).to be_sent
    expect(ActionMailer::Base.deliveries.last.to).to eq([ "stamp@example.com" ])
  end
end
