require "rails_helper"

RSpec.describe DocusealJobs::CreateMinorWaiverJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:participant_event) { create(:participant_event) }
  let!(:guardian_participant_event) { create(:guardian_participant_event, participant_event: participant_event) }
  let(:consent) { create(:consent, participant_event: participant_event, status: :pending) }
  let(:client) { instance_double(Docuseal::Client) }

  before do
    allow(Docuseal::Client).to receive(:for).and_return(client)
    allow(client).to receive(:get_template).and_return({
      "submitters" => [ { "name" => "Attendee" }, { "name" => "Parent/Legal Guardian" } ],
      "fields" => []
    })
    allow(client).to receive(:create_submission).and_return([
      { "role" => "Attendee", "slug" => "teen-slug", "submission_id" => 9 },
      { "role" => "Parent/Legal Guardian", "slug" => "guardian-slug", "submission_id" => 9 }
    ])
  end

  it "emails the teen their signing link" do
    expect {
      described_class.perform_now(consent.id)
    }.to have_enqueued_mail(ParticipantMailer, :waiver_ready)

    expect(consent.reload.docuseal_participant_slug).to eq("teen-slug")
  end

  # The teen is usually on the waiver page signing in the embed, so the email
  # waits long enough for the mailer to see they've signed and skip it.
  it "delays the signing link email" do
    freeze_time do
      expect {
        described_class.perform_now(consent.id)
      }.to have_enqueued_mail(ParticipantMailer, :waiver_ready).at(10.minutes.from_now)
    end
  end

  it "explains the new dates when it replaces a waiver voided by a date change" do
    expect {
      described_class.perform_now(consent.id, dates_changed: true)
    }.to have_enqueued_mail(ParticipantMailer, :waiver_dates_changed)
  end
end
