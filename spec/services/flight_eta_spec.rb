require "rails_helper"

RSpec.describe FlightEta do
  let(:scheduled_arr) { Time.zone.parse("2026-05-09 14:00") }
  let(:stored_arr)    { scheduled_arr }

  def leg(tracking: {}, live_status: nil, picked_up: false)
    double(
      "TravelLeg",
      live_tracking_data: tracking,
      live_status: live_status,
      live_arrival_time: nil,
      arrival_time: stored_arr,
      picked_up?: picked_up
    )
  end

  it "uses predicted_arrival when status is in flight" do
    eta_at = scheduled_arr + 30.minutes
    r = FlightEta.for(leg(
      live_status: "EnRoute",
      tracking: { scheduled_arrival: scheduled_arr.iso8601, predicted_arrival: eta_at.iso8601 }
    ))
    expect(r.status).to eq(:in_flight)
    expect(r.eta).to be_within(1.second).of(eta_at)
    expect(r.eta_source).to eq(:predicted)
    expect(r.is_delayed).to be true
    expect(r.delay_minutes).to eq(30)
  end

  it "uses scheduled_arrival when no prediction yet" do
    r = FlightEta.for(leg(
      live_status: "Scheduled",
      tracking: { scheduled_arrival: scheduled_arr.iso8601 }
    ))
    expect(r.status).to eq(:scheduled)
    expect(r.eta_source).to eq(:scheduled)
    expect(r.is_delayed).to be false
    expect(r.delay_minutes).to eq(0)
  end

  it "falls back to stored arrival_time when no live data at all" do
    r = FlightEta.for(leg(live_status: nil, tracking: {}))
    expect(r.eta).to be_within(1.second).of(stored_arr)
    expect(r.eta_source).to eq(:stored)
    expect(r.delay_minutes).to eq(0)
  end

  it "marks landed flights with status :landed using actual arrival" do
    actual = scheduled_arr + 5.minutes
    r = FlightEta.for(leg(
      live_status: "Arrived",
      tracking: { scheduled_arrival: scheduled_arr.iso8601, predicted_arrival: actual.iso8601 }
    ))
    expect(r.status).to eq(:landed)
    expect(r.eta_source).to eq(:actual)
    expect(r.eta).to be_within(1.second).of(actual)
    expect(r.is_delayed).to be false # 5min < 15min threshold
  end

  it "promotes landed → picked_up when leg is picked up" do
    r = FlightEta.for(leg(live_status: "Arrived", tracking: {}, picked_up: true))
    expect(r.status).to eq(:picked_up)
  end

  it "normalises Cancelled" do
    r = FlightEta.for(leg(live_status: "Cancelled", tracking: { scheduled_arrival: scheduled_arr.iso8601 }))
    expect(r.status).to eq(:cancelled)
    expect(r.alert?).to be true
  end

  it "normalises Diverted" do
    r = FlightEta.for(leg(live_status: "Diverted", tracking: {}))
    expect(r.status).to eq(:diverted)
  end

  it "treats AeroDataBox 'Delayed' as scheduled with delay flag from times" do
    eta_at = scheduled_arr + 45.minutes
    r = FlightEta.for(leg(
      live_status: "Delayed",
      tracking: { scheduled_arrival: scheduled_arr.iso8601, predicted_arrival: eta_at.iso8601 }
    ))
    expect(r.status).to eq(:scheduled)
    expect(r.is_delayed).to be true
    expect(r.delay_minutes).to eq(45)
  end

  it "handles nil arrival times gracefully" do
    bare = double("TravelLeg", live_tracking_data: nil, live_status: nil, live_arrival_time: nil, arrival_time: nil, picked_up?: false)
    r = FlightEta.for(bare)
    expect(r.eta).to be_nil
    expect(r.known_eta?).to be false
    expect(r.status).to eq(:scheduled)
  end
end
