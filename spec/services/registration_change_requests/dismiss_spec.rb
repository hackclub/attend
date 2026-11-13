require "rails_helper"

RSpec.describe RegistrationChangeRequests::Dismiss do
  let(:participant_event) { create(:participant_event) }
  let(:owner) { create(:user) }
  let(:reviewer) { create(:user) }
  let(:request) do
    participant_event.participant.update!(user: owner)
    RegistrationChangeRequest.create!(participant_event: participant_event, requested_by: owner,
      kind: :support, staff_audience: :operations, requested_changes: {}, requester_note: "Never mind")
  end

  it "closes the request without emailing the participant" do
    expect {
      described_class.call(request: request, reviewer: reviewer)
    }.not_to have_enqueued_mail(RegistrationCorrectionMailer)

    expect(request.reload).to have_attributes(status: "dismissed", resolved_by: reviewer)
    expect(request.resolved_at).to be_present
    expect(request.participant_status_label).to eq("Closed")
  end

  it "refuses a request that is already resolved" do
    request.update!(status: :approved)

    expect { described_class.call(request: request, reviewer: reviewer) }.to raise_error(ArgumentError)
  end

  it "lets the participant file a new request of the same kind afterwards" do
    described_class.call(request: request, reviewer: reviewer)

    expect(
      RegistrationChangeRequest.new(participant_event: participant_event, requested_by: owner,
        kind: :support, staff_audience: :operations, requester_note: "Actually, one more thing")
    ).to be_valid
  end
end
