require "rails_helper"

RSpec.describe RegistrationChangeRequests::Approve do
  let(:event) { create(:event) }
  let(:participant) { create(:participant, legal_first_name: "Old", legal_last_name: "Name") }
  let(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let(:owner) { create(:user) }
  let(:reviewer) { create(:user) }

  before do
    participant.update!(user: owner)
    create(:event_role_assignment, event: event, user: reviewer, role: :event_admin)
  end

  it "applies an identity request when no registration has identity-bound acceptance" do
    request = create_request(
      kind: :signed_identity,
      requested_changes: { "legal_first_name" => "New", "legal_last_name" => "Name" }
    )

    result = described_class.call(request: request, reviewer: reviewer)

    expect(result).to eq(:approved)
    expect(participant.reload.legal_first_name).to eq("New")
    expect(request.reload).to be_approved
    expect(request.resolved_by).to eq(reviewer)
    expect(request.resolved_at).to be_present
  end

  it "keeps a shared identity change in follow-up when any event has identity-bound acceptance" do
    other_event = create(:event)
    other_registration = create(:participant_event, event: other_event, participant: participant,
      code_of_conduct_accepted_at: 1.day.ago, code_of_conduct_signature: "Old Name")
    create(:consent, participant_event: other_registration, consent_type: :waiver, status: :signed)
    request = create_request(
      kind: :signed_identity,
      requested_changes: { "legal_first_name" => "New" }
    )

    result = described_class.call(request: request, reviewer: reviewer)

    expect(result).to eq(:follow_up_needed)
    expect(participant.reload.legal_first_name).to eq("Old")
    expect(request.reload).to be_follow_up_needed
    expect(request.staff_response).to include("signed registrations")
  end

  it "replaces a guardian without carrying the previous guardian's consent" do
    participant_event.update!(status: :complete, code_of_conduct_accepted_at: 1.day.ago)
    old_guardian = create(:guardian, email: "old-guardian@example.com")
    old_link = create(:guardian_participant_event, participant_event: participant_event,
      guardian: old_guardian, status: :completed, is_primary_guardian: true,
      invite_token_ciphertext: "old-token", invite_token_digest: "old-digest")
    consent = Consent.create!(
      participant_event: participant_event,
      guardian_participant_event: old_link,
      consent_type: :waiver,
      status: :signed,
      docuseal_envelope_id: "submission-1",
      docuseal_guardian_slug: "guardian-slug",
      guardian_signed_at: 1.day.ago,
      participant_signed_at: 1.day.ago,
      signed_at: 1.day.ago
    )
    request = create_request(
      kind: :guardian,
      requested_changes: {
        "legal_first_name" => "New",
        "legal_last_name" => "Guardian",
        "email" => "new-guardian@example.com",
        "phone" => "+12025550999",
        "relationship" => "Parent"
      }
    )

    expect {
      @result = described_class.call(request: request, reviewer: reviewer)
    }.to have_enqueued_job(SendPendingGuardianInvitesJob).with(event.id)

    new_link = participant_event.guardian_participant_events.reload.sole
    expect(@result).to eq(:approved)
    expect(new_link.guardian.email).to eq("new-guardian@example.com")
    expect(new_link).to be_pending
    expect(new_link).to be_is_primary_guardian
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(false)
    expect(old_guardian.reload.email).to eq("old-guardian@example.com")
    expect(consent.reload.guardian_participant_event).to eq(new_link)
    expect(consent).to be_pending
    expect(consent.attributes.values_at(
      "docuseal_envelope_id", "docuseal_guardian_slug", "guardian_signed_at",
      "participant_signed_at", "signed_at"
    )).to all(be_nil)
    expect(participant_event.reload).to be_awaiting_guardian
    expect(request.reload).to be_approved
  end

  it "preserves guardian-managed emergency contacts when replacing the guardian" do
    old_link = create(:guardian_participant_event, participant_event: participant_event,
      is_primary_guardian: true)
    emergency_contact = EmergencyContact.create!(
      guardian_participant_event: old_link,
      name: "Emergency Person",
      phone: "+12025550198",
      relationship: "Aunt",
      priority: 1
    )
    request = create_request(
      kind: :guardian,
      requested_changes: {
        "legal_first_name" => "New",
        "legal_last_name" => "Guardian",
        "email" => "replacement-guardian@example.com",
        "phone" => "+12025550997",
        "relationship" => "Parent"
      }
    )

    expect(described_class.call(request: request, reviewer: reviewer)).to eq(:approved)

    new_link = participant_event.guardian_participant_events.reload.sole
    expect(emergency_contact.reload.guardian_participant_event).to eq(new_link)
    expect(emergency_contact.name).to eq("Emergency Person")
    expect(emergency_contact.phone).to eq("+12025550198")
  end

  it "does not approve a guardian replacement after the participant becomes an adult" do
    create(:guardian_participant_event, participant_event: participant_event,
      is_primary_guardian: true)
    request = create_request(
      kind: :guardian,
      requested_changes: {
        "legal_first_name" => "New",
        "legal_last_name" => "Guardian",
        "email" => "adult-guardian@example.com",
        "phone" => "+12025550996",
        "relationship" => "Parent"
      }
    )
    participant.update!(date_of_birth: 25.years.ago)

    expect(described_class.call(request: request, reviewer: reviewer)).to eq(:follow_up_needed)

    expect(request.reload).to be_follow_up_needed
    expect(participant_event.guardian_participant_events.count).to eq(1)
  end

  it "does not enqueue guardian delivery while invitations are locked" do
    event.update!(guardian_invites_locked: true)
    old_link = create(:guardian_participant_event, participant_event: participant_event)
    request = create_request(
      kind: :guardian,
      requested_changes: {
        "legal_first_name" => "New",
        "legal_last_name" => "Guardian",
        "email" => "locked-guardian@example.com",
        "phone" => "+12025550998",
        "relationship" => "Parent"
      }
    )

    expect {
      described_class.call(request: request, reviewer: reviewer)
    }.not_to have_enqueued_job(SendPendingGuardianInvitesJob)

    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(false)
    expect(participant_event.reload).to be_awaiting_guardian
    expect(participant_event.guardian_participant_events.sole.invite_token_sent_at).to be_nil
  end

  it "resolves support requests without mutating registration data" do
    request = create_request(
      kind: :support,
      staff_audience: :operations,
      requested_changes: {},
      requester_note: "private accommodation question"
    )

    expect {
      expect(described_class.call(request: request, reviewer: reviewer)).to eq(:approved)
    }.not_to change { participant.reload.attributes }

    expect(request.reload).to be_approved
  end

  def create_request(kind:, requested_changes:, staff_audience: :event_admin, requester_note: nil)
    RegistrationChangeRequest.create!(
      participant_event: participant_event,
      requested_by: owner,
      kind: kind,
      staff_audience: staff_audience,
      requested_changes: requested_changes,
      requester_note: requester_note
    )
  end
end
