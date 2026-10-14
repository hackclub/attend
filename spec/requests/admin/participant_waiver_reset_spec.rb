require "rails_helper"

# Resetting a single participant's waiver by hand goes through
# Consent#reset_for_reissue!, the same reset the bulk date-change re-issue uses.
RSpec.describe "Admin::Participants waiver reset", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) { create(:participant, date_of_birth: 16.years.ago) }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let!(:guardian_participant_event) { create(:guardian_participant_event, participant_event: participant_event, status: :completed) }

  before do
    user = User.create!(email: "event-admin-reset@example.com", name: "Event Admin")
    EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    sign_in user
  end

  it "puts the waiver back to pending, reopens the guardian and emails them" do
    waiver = create(:consent, participant_event: participant_event, status: :signed, docuseal_envelope_id: "sub_old",
      docuseal_participant_slug: "p", docuseal_guardian_slug: "g", docuseal_host: "https://old.example.com",
      signed_at: 1.day.ago, pending_on: "guardian", sent_at: 2.days.ago)

    expect {
      delete reset_waiver_admin_event_participant_path(event.slug, participant_event)
    }.to have_enqueued_mail(GuardianMailer, :waiver_reset)

    expect(response).to redirect_to(consents_admin_event_participant_path(event.slug, participant_event))
    waiver.reload
    expect(waiver).to be_pending
    expect(waiver.docuseal_envelope_id).to be_nil
    expect(waiver.docuseal_guardian_slug).to be_nil
    expect(waiver.pending_on).to be_nil
    expect(waiver.sent_at).to be_nil
    # Only the bulk date-change path moves a consent onto the event's host.
    expect(waiver.docuseal_host).to eq("https://old.example.com")
    expect(guardian_participant_event.reload).to be_in_progress
  end

  it "makes the guardian choose again on a reset freedom waiver" do
    freedom = create(:consent, :freedom_waiver, participant_event: participant_event, status: :signed,
      docuseal_envelope_id: "sub_f", docuseal_guardian_slug: "g")
    safeguarding_info = SafeguardingInfo.create!(participant_event: participant_event, freedom_waiver_granted: true)

    expect {
      delete reset_freedom_waiver_admin_event_participant_path(event.slug, participant_event)
    }.to have_enqueued_mail(GuardianMailer, :waiver_reset)

    expect(freedom.reload).to be_pending
    expect(freedom.docuseal_guardian_slug).to be_nil
    expect(safeguarding_info.reload.freedom_waiver_granted).to be(false)
    expect(guardian_participant_event.reload).to be_in_progress
  end
end
