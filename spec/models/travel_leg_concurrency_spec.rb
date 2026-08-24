require "rails_helper"

RSpec.describe "TravelLeg pickup concurrency", type: :model do
  self.use_transactional_tests = false

  it "preserves the first pickup timestamp and actor when scanners race" do
    record_ids = []
    first_user = create(:user)
    second_user = create(:user)
    event = create(:event)
    participant = create(:participant)
    participant_event = create(:participant_event, event: event, participant: participant)
    travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "plane")
    leg = create(
      :travel_leg,
      travel: travel,
      departure_airport: "JFK",
      arrival_airport: "LHR"
    )
    record_ids.concat([ event.id, participant.id, participant_event.id, travel.id, leg.id ])

    first_has_lock = Queue.new
    release_first = Queue.new
    second_has_loaded_stale_state = Queue.new

    first_scanner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TravelLeg.transaction do
          locked_leg = TravelLeg.lock.find(leg.id)
          first_has_lock << true
          release_first.pop
          locked_leg.mark_travel_picked_up!(first_user)
          locked_leg.reload.travel_picked_up_at
        end
      end
    end

    first_has_lock.pop

    second_scanner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale_leg = TravelLeg.find(leg.id)
        second_has_loaded_stale_state << true
        stale_leg.mark_travel_picked_up!(second_user)
      end
    end

    second_has_loaded_stale_state.pop
    release_first << true
    first_pickup_time = first_scanner.value
    second_scanner.value

    leg.reload
    expect(leg.travel_picked_up_at).to eq(first_pickup_time)
    expect(leg.picked_up_by).to eq(first_user)
  ensure
    event&.destroy!
    participant&.destroy!
    first_user&.destroy!
    second_user&.destroy!
    PaperTrail::Version.where(item_id: record_ids).delete_all
  end
end
