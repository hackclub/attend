require "rails_helper"

RSpec.describe Registration::Transition do
  let(:event) { create(:event, travel_enabled: true, accommodation_enabled: false, freedom_waivers_enabled: false) }
  let(:adult) { create(:participant, date_of_birth: 18.years.ago - 1.month) }
  let(:participant_event) { create(:participant_event, participant: adult, event: event, status: :invited) }
  let(:staff) { create(:user) }

  def history
    participant_event.registration_transitions.chronological.map { |t| [ t.from_status, t.to_status, t.cause ] }
  end

  it "records the registration being created" do
    expect(history).to eq([ [ nil, "invited", "created" ] ])
  end

  describe "ParticipantEvent#transition_to!" do
    it "writes the status and records why, who and what's still outstanding" do
      expect(participant_event.transition_to!(:in_progress, cause: :started, actor: staff, metadata: { via: "spec" })).to be(true)

      transition = participant_event.registration_transitions.chronological.last
      expect(participant_event.reload).to be_in_progress
      expect(transition).to have_attributes(
        from_status: "invited", to_status: "in_progress", cause: "started",
        actor: staff, blocking_requirement: "travel", metadata: { "via" => "spec" }
      )
    end

    it "takes the actor from the request when none is given" do
      Current.user = staff
      participant_event.transition_to!(:withdrawn, cause: :withdrawn)

      expect(participant_event.registration_transitions.chronological.last.actor).to eq(staff)
    ensure
      Current.reset
    end

    it "does nothing when the registration is already there" do
      expect(participant_event.transition_to!(:invited, cause: :staff_set)).to be(false)
      expect(history.size).to eq(1)
    end

    it "records nothing when the change is refused" do
      expect { participant_event.transition_to!(:rejected, cause: :rejected) }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(participant_event.reload).to be_invited
      expect(history.size).to eq(1)
    end

    it "doesn't leave its cause behind for the next save" do
      participant_event.transition_to!(:in_progress, cause: :started)
      participant_event.update!(status: :awaiting_guardian)

      expect(history.last).to eq([ "in_progress", "awaiting_guardian", "untracked" ])
    end
  end

  it "still records a status change that bypassed #transition_to!, as untracked" do
    participant_event.update!(status: :complete)

    expect(history.last).to eq([ "invited", "complete", "untracked" ])
  end

  describe "ParticipantEvent#reopen!" do
    it "sends a complete registration back to in progress" do
      participant_event.update_columns(status: "complete")

      expect(participant_event.reopen!(cause: :document_added)).to be(true)
      expect(history.last).to eq([ "complete", "in_progress", "document_added" ])
    end

    it "leaves anything that isn't complete alone" do
      expect(participant_event.reopen!(cause: :document_added)).to be(false)
      expect(participant_event.reload).to be_invited
    end
  end

  describe "ParticipantEvent#mark_complete_if_eligible!" do
    it "records what completed the registration" do
      participant_event.update_columns(status: "in_progress", code_of_conduct_accepted_at: Time.current)
      create(:consent, :signed, participant_event: participant_event)

      expect(participant_event.reload.mark_complete_if_eligible!(cause: :submitted)).to be(true)
      expect(history.last).to eq([ "in_progress", "complete", "submitted" ])
      expect(participant_event.reload.onboarding_completed_at).to be_present
    end
  end

  describe ".staff_cause_for" do
    it "names withdrawing, rejecting and undoing either; anything else is staff_set" do
      expect(described_class.staff_cause_for("withdrawn", from: "complete")).to eq(:withdrawn)
      expect(described_class.staff_cause_for("rejected", from: "in_progress")).to eq(:rejected)
      expect(described_class.staff_cause_for("in_progress", from: "withdrawn")).to eq(:reinstated)
      expect(described_class.staff_cause_for("complete", from: "rejected")).to eq(:reinstated)
      expect(described_class.staff_cause_for("complete", from: "in_progress")).to eq(:staff_set)
    end
  end

  it "goes when the registration does" do
    participant_event.transition_to!(:in_progress, cause: :started)

    expect { participant_event.destroy! }.to change(described_class, :count).by(-2)
  end
end
