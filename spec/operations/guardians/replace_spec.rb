require "rails_helper"

RSpec.describe Guardians::Replace do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:participant) { create(:participant, email: "camper@example.com", phone: "+12025550100") }
  let(:participant_event) do
    fill_in_registration_answers(create(:participant_event, event: event, participant: participant)).tap do |pe|
      pe.update!(status: :complete, code_of_conduct_accepted_at: 1.day.ago)
    end
  end
  let(:old_guardian) { create(:guardian, legal_first_name: "Pat", legal_last_name: "Wrongparent", email: "pat@example.com") }
  let!(:old_link) do
    create(:guardian_participant_event, participant_event: participant_event, guardian: old_guardian,
      status: :completed, is_primary_guardian: true, relationship: "Parent")
  end
  let!(:waiver) do
    Consent.create!(participant_event: participant_event, guardian_participant_event: old_link,
      consent_type: :waiver, status: :signed, docuseal_envelope_id: "sub-1", docuseal_guardian_slug: "g-slug",
      guardian_signed_at: 1.day.ago, signed_at: 1.day.ago, document_url: "https://example.com/signed.pdf")
  end
  let(:global_admin) { create(:user, global_role: "global_admin") }
  let(:new_details) do
    { legal_first_name: "Robin", legal_last_name: "Rightparent", email: "Robin@Example.com",
      phone: "+12025550188", relationship: "Parent" }
  end

  around { |example| Current.set(event: event) { example.run } }

  def context_for(user, surface: :html)
    Operation::Context.new(surface: surface, user: user, event: event)
  end

  def replace(user = global_admin, attributes: new_details, reference: old_link)
    described_class.call(context_for(user), participant_event: participant_event,
      guardian_participant_event: reference, attributes: attributes)
  end

  it "swaps the guardian, resets what they signed and invites the new one" do
    emergency_contact = EmergencyContact.create!(guardian_participant_event: old_link, name: "Alex Neighbour",
      phone: "+12025550177")

    result = nil
    expect { result = replace }.to have_enqueued_mail(GuardianMailer, :invitation)

    expect(result).to be_success
    new_link = result.value.link
    expect(new_link.guardian).to have_attributes(legal_first_name: "Robin", legal_last_name: "Rightparent",
      email: "robin@example.com", phone: "+12025550188")
    expect(new_link).to be_pending
    expect(new_link.relationship).to eq("Parent")
    expect(new_link.is_primary_guardian).to be(true)
    expect(result.value).to be_invited

    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(false)
    expect(participant_event.guardian_participant_events.reload).to eq([ new_link ])
    expect(waiver.reload).to have_attributes(status: "pending", guardian_participant_event_id: new_link.id,
      docuseal_envelope_id: nil, guardian_signed_at: nil, signed_at: nil, document_url: nil)
    expect(emergency_contact.reload.guardian_participant_event).to eq(new_link)
    expect(participant_event.reload).to be_awaiting_guardian
  end

  it "audits the swap by name with the old link and the reset documents" do
    result = replace

    log = AuditLog.sole
    expect(log.action).to eq("replace_guardian")
    expect(log.record).to eq(result.value.link)
    expect(log.changed_fields).to eq("guardian_id" => [ old_guardian.id, result.value.link.guardian_id ])
    expect(log.metadata).to include(
      "participant_event_id" => participant_event.id,
      "replaced_guardian_participant_event_id" => old_link.id,
      "replaced_guardian_status" => "completed",
      "reset_consent_ids" => [ waiver.id ],
      "invited" => true
    )
  end

  it "leaves an unsubmitted registration with the participant and doesn't invite yet" do
    participant_event.update!(status: :in_progress, code_of_conduct_accepted_at: nil)

    result = nil
    expect { result = replace }.not_to have_enqueued_mail(GuardianMailer, :invitation)

    expect(result).to be_success
    expect(result.value).not_to be_invited
    expect(participant_event.reload).to be_in_progress
  end

  it "doesn't invite while the event has guardian invites locked" do
    allow_any_instance_of(Event).to receive(:guardian_invites_locked?).and_return(true)

    result = nil
    expect { result = replace }.not_to have_enqueued_mail(GuardianMailer, :invitation)
    expect(result.value).not_to be_invited
  end

  it "is held to global admins, even an event admin of this event" do
    event_admin = create(:user).tap { |user| EventRoleAssignment.create!(user: user, event: event, role: "event_admin") }

    expect { replace(event_admin) }.to raise_error(Pundit::NotAuthorizedError)

    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
    expect(waiver.reload).to be_signed
    expect(AuditLog.count).to eq(0)
  end

  it "refuses a registration that doesn't need a guardian" do
    allow_any_instance_of(ParticipantEvent).to receive(:requires_guardian?).and_return(false)

    expect(replace.code).to eq(:no_guardian_required)
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
  end

  it "requires a name and email for the new guardian" do
    result = replace(attributes: new_details.merge(legal_last_name: " ", email: ""))

    expect(result.code).to eq(:missing_details)
    expect(result.message).to include("legal last name", "email")
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
  end

  it "refuses the participant's own email and changes nothing" do
    result = replace(attributes: new_details.merge(email: "camper@example.com"))

    expect(result.code).to eq(:invalid)
    expect(result.record).to be_a(Guardian)
    expect(result.record.errors[:email]).to be_present
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
    expect(waiver.reload).to be_signed
    expect(Guardian.where(email: "camper@example.com")).to be_empty
  end

  it "refuses the participant's own phone" do
    result = replace(attributes: new_details.merge(phone: "+12025550100"))

    expect(result.code).to eq(:invalid)
    expect(result.record.errors[:phone]).to be_present
  end

  it "leaves a guardian-signed paper document for staff to handle by hand" do
    allow(Guardians::Replacement).to receive(:needs_manual_follow_up?).and_return(true)

    expect(replace.code).to eq(:manual_follow_up)
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
  end

  it "sends nothing and changes nothing when the run is rolled back" do
    allow(AuditLog).to receive(:log!).and_raise(ActiveRecord::StatementInvalid, "audit_logs is unavailable")

    expect {
      expect { replace }.to raise_error(ActiveRecord::StatementInvalid)
    }.not_to have_enqueued_mail(GuardianMailer, :invitation)
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
    expect(waiver.reload).to be_signed
  end

  it "refuses an anonymized connection" do
    context = Operation::Context.new(surface: :mcp, user: global_admin, event: event, anonymized: true)

    result = described_class.call(context, participant_event: participant_event,
      guardian_participant_event: old_link.id, attributes: new_details)

    expect(result.code).to eq(:anonymized)
    expect(GuardianParticipantEvent.exists?(old_link.id)).to be(true)
  end
end
