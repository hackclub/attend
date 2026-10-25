require "rails_helper"

RSpec.describe RegistrationChangeRequest, type: :model do
  let(:participant_event) { create(:participant_event) }
  let(:requester) { create(:user, participant: participant_event.participant) }

  def build_request(**attributes)
    described_class.new({
      participant_event: participant_event,
      requested_by: requester,
      kind: :signed_identity,
      staff_audience: :event_admin,
      requested_changes: { "legal_first_name" => "Corrected" }
    }.merge(attributes))
  end

  it "allows only one pending request of each kind for a registration" do
    build_request.save!

    duplicate = build_request

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:kind]).to include("already has a pending request")
  end

  it "allows a new request after the earlier request needs follow-up" do
    build_request(status: :follow_up_needed).save!

    expect(build_request).to be_valid
  end

  it "requires identity and guardian requests to use the event-admin audience" do
    request = build_request(staff_audience: :safeguarding)

    expect(request).not_to be_valid
    expect(request.errors[:staff_audience]).to include("must be event admin for this request")
  end

  it "supports private requests for precise operational and safeguarding audiences" do
    operations = build_request(
      kind: :support,
      staff_audience: :operations,
      requested_changes: {},
      requester_note: "I need to discuss rooming privately."
    )
    safeguarding = build_request(
      kind: :support,
      staff_audience: :safeguarding,
      requested_changes: {},
      requester_note: "I need to discuss a health issue privately."
    )

    expect(operations).to be_valid
    expect(safeguarding).to be_valid
  end

  it "encrypts request details at rest" do
    request = build_request(requester_note: "private correction context")
    request.save!

    raw = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
      SELECT requested_changes, requester_note
      FROM registration_change_requests
      WHERE id = '#{request.id}'
    SQL

    expect(raw.fetch("requested_changes")).not_to include("Corrected")
    expect(raw.fetch("requester_note")).not_to include("private correction context")
  end
end
