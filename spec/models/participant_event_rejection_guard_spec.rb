require "rails_helper"

# Rejecting a registration, or undoing it, is an event-admin decision, but
# update? lets ops, limited and the participant themselves through. The model
# refuses any status change into or out of rejected unless the caller checked
# the stricter policy and opted in, so a path that forgets fails loudly.
RSpec.describe ParticipantEvent, "rejection guard" do
  let(:participant_event) { create(:participant_event, status: :in_progress) }

  it "refuses to reject without authorization" do
    expect { participant_event.update!(status: :rejected) }
      .to raise_error(ActiveRecord::RecordInvalid, /rejected by an event admin/)
    expect(participant_event.reload.status).to eq("in_progress")
  end

  it "refuses to move out of rejected without authorization" do
    participant_event.transition_to!(:rejected, cause: :rejected, rejection_authorized: true)

    expect { participant_event.in_progress! }.to raise_error(ActiveRecord::RecordInvalid)
    expect { participant_event.update!(status: :withdrawn) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(participant_event.reload.status).to eq("rejected")
  end

  it "allows both directions once authorized" do
    participant_event.transition_to!(:rejected, cause: :rejected, rejection_authorized: true)
    expect(participant_event.reload.status).to eq("rejected")

    participant_event.transition_to!(:in_progress, cause: :reinstated, rejection_authorized: true)
    expect(participant_event.reload.status).to eq("in_progress")
  end

  it "doesn't carry the authorization over to the next save" do
    participant_event.transition_to!(:rejected, cause: :rejected, rejection_authorized: true)

    expect(participant_event.rejection_change_authorized).to be_nil
    expect { participant_event.in_progress! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "leaves other status changes and other edits on a rejected row alone" do
    participant_event.withdrawn!
    participant_event.in_progress!
    expect(participant_event.reload.status).to eq("in_progress")

    participant_event.transition_to!(:rejected, cause: :rejected, rejection_authorized: true)
    participant_event.update!(onboarding_step: 3)
    expect(participant_event.reload.onboarding_step).to eq(3)
  end
end
