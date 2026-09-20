require "rails_helper"

RSpec.describe Travel, type: :model do
  let(:participant_event) { create(:participant_event) }

  it "keeps legacy travel unresolved by default" do
    travel = participant_event.travels.create!(direction: :inbound, mode: :car)

    expect(travel).to be_unknown
    expect(participant_event.reload).to be_travel_outstanding
  end

  it "accepts a provisional intended mode without booking details" do
    travel = participant_event.travels.build(
      direction: :inbound,
      arrangement_status: :provisional,
      mode: :train
    )

    expect(travel).to be_valid
  end

  it "requires complete mode-specific details when confirmed" do
    travel = participant_event.travels.build(
      direction: :inbound,
      arrangement_status: :confirmed,
      mode: :train
    )

    expect(travel).not_to be_valid
    expect(travel.errors.full_messages).to include(
      "Train departure station can't be blank",
      "Train arrival station can't be blank",
      "Arrival time can't be blank"
    )
  end

  it "is ready only when both directions are confirmed" do
    participant_event.travels.create!(direction: :inbound, arrangement_status: :confirmed,
      mode: :other, other_details: "Walking")
    participant_event.travels.create!(direction: :outbound, arrangement_status: :provisional,
      mode: :train)

    expect(participant_event.reload).not_to be_travel_ready
    expect(participant_event).to be_travel_outstanding

    participant_event.travel_outbound.update!(arrangement_status: :confirmed,
      train_departure_station: "Central", train_arrival_station: "Home", departure_time: 1.week.from_now)

    expect(participant_event.reload).to be_travel_ready
    expect(participant_event).not_to be_travel_outstanding
  end
end
