require "rails_helper"

RSpec.describe RegistrationChangeRequestPolicy do
  let(:event) { create(:event) }
  let(:participant) { create(:participant) }
  let(:participant_event) { create(:participant_event, event: event, participant: participant) }
  let(:owner) { create(:user) }
  let(:request) do
    participant.update!(user: owner)
    RegistrationChangeRequest.create!(
      participant_event: participant_event,
      requested_by: owner,
      kind: :signed_identity,
      staff_audience: :event_admin,
      requested_changes: { "legal_first_name" => "Corrected" }
    )
  end

  after { Current.reset }

  it "allows the attendee owner to create and see their request" do
    policy = described_class.new(owner, request)

    expect(policy.create?).to be(true)
    expect(policy.show?).to be(true)
    expect(policy.approve?).to be(false)
  end

  it "does not expose a child's request to their guardian" do
    guardian_user = create(:user)
    guardian = create(:guardian, user: guardian_user)
    create(:guardian_participant_event, participant_event: participant_event, guardian: guardian)

    policy = described_class.new(guardian_user, request)

    expect(policy.show?).to be(false)
    expect(described_class::Scope.new(guardian_user, RegistrationChangeRequest).resolve).to be_empty
  end

  it "allows an event admin to resolve only requests for that event" do
    admin = create(:user)
    create(:event_role_assignment, event: event, user: admin, role: :event_admin)
    other_request = create_request_for(create(:event))
    Current.event = event

    policy = described_class.new(admin, request)
    visible = described_class::Scope.new(admin, RegistrationChangeRequest).resolve

    expect(policy.approve?).to be(true)
    expect(visible).to contain_exactly(request)
    expect(visible).not_to include(other_request)
  end

  it "restricts a safeguarding support request to the safeguarding audience" do
    support = request.dup
    support.assign_attributes(
      kind: :support,
      staff_audience: :safeguarding,
      requested_changes: {},
      requester_note: "private health question"
    )
    support.save!
    safeguarding = create(:user)
    ops = create(:user)
    create(:event_role_assignment, event: event, user: safeguarding, role: :safeguarding_lead)
    create(:event_role_assignment, event: event, user: ops, role: :ops)
    Current.event = event

    expect(described_class.new(safeguarding, support).show?).to be(true)
    expect(described_class.new(ops, support).show?).to be(false)
  end

  it "restricts an operations support request to event admins and ops" do
    support = request.dup
    support.assign_attributes(
      kind: :support,
      staff_audience: :operations,
      requested_changes: {},
      requester_note: "private accommodation question"
    )
    support.save!
    ops = create(:user)
    safeguarding = create(:user)
    create(:event_role_assignment, event: event, user: ops, role: :ops)
    create(:event_role_assignment, event: event, user: safeguarding, role: :safeguarding_lead)
    Current.event = event

    expect(described_class.new(ops, support).show?).to be(true)
    expect(described_class.new(safeguarding, support).show?).to be(false)
  end

  def create_request_for(other_event)
    other_participant = create(:participant)
    other_owner = create(:user)
    other_participant.update!(user: other_owner)
    other_participant_event = create(:participant_event, event: other_event, participant: other_participant)
    RegistrationChangeRequest.create!(
      participant_event: other_participant_event,
      requested_by: other_owner,
      kind: :support,
      staff_audience: :event_admin,
      requested_changes: {},
      requester_note: "other event request"
    )
  end
end
