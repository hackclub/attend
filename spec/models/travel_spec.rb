require "rails_helper"

RSpec.describe Travel, type: :model do
  describe "#dismiss_pickup!" do
    it "rejects outbound travel without changing pickup state" do
      travel = Travel.create!(
        participant_event: create(:participant_event),
        direction: "outbound",
        mode: "bus"
      )

      expect { travel.dismiss_pickup! }.to raise_error(ActiveRecord::RecordInvalid, /inbound travel/)
      expect(travel.reload.pickup_dismissed_at).to be_nil
      expect(travel).not_to be_pickup_dismissed
    end
  end

  # Train, bus and car times are typed in datetime-local fields on the event's
  # clock. 2026-07-12 is EDT (UTC-4) in New York.
  describe "event-local times" do
    let(:event) { create(:event, timezone: "America/New_York") }
    let(:participant_event) { create(:participant_event, event: event) }
    let(:new_york) { ActiveSupport::TimeZone["America/New_York"] }

    # A row saved before times_in_event_zone: its typed times were cast as
    # UTC wall-clock. Written around the model so the flag stays false.
    def legacy_travel(**times)
      travel = participant_event.travels.create!(direction: "inbound", mode: "bus")
      travel.update_columns(times_in_event_zone: false, **times)
      Travel.find(travel.id)
    end

    it "reads the event's zone on a travel built off its participant event but not yet saved" do
      travel = participant_event.travels.build(direction: "inbound")

      expect(travel).to be_new_record
      expect(travel.event_local_time_zone).to eq(new_york)
    end

    it "stores typed train, bus and car times as that wall-clock in the event's zone" do
      travel = participant_event.travels.build(direction: "inbound", mode: "bus")
      travel.assign_attributes(
        departure_time: "2026-07-12T06:15",
        arrival_time: "2026-07-12T09:30",
        expected_arrival_time: "2026-07-12 10:00"
      )
      travel.save!

      travel.reload
      expect(travel.times_in_event_zone).to be(true)
      expect(travel.departure_time).to eq(Time.utc(2026, 7, 12, 10, 15))
      expect(travel.arrival_time).to eq(Time.utc(2026, 7, 12, 13, 30))
      expect(travel.expected_arrival_time).to eq(Time.utc(2026, 7, 12, 14, 0))
      expect(travel.local_time_field_value(:arrival_time)).to eq("2026-07-12T09:30")
      expect(travel.local_time(:arrival_time).time_zone).to eq(new_york)
    end

    it "leaves a time that names its own offset alone" do
      travel = participant_event.travels.create!(direction: "inbound", mode: "train",
        arrival_time: "2026-07-12T09:30:00Z")

      expect(travel.reload.arrival_time).to eq(Time.utc(2026, 7, 12, 9, 30))
    end

    it "keeps rendering a legacy row on UTC, as it was typed" do
      travel = legacy_travel(arrival_time: Time.utc(2026, 7, 12, 9, 30))

      expect(travel.time_display_zone).to eq(ActiveSupport::TimeZone["UTC"])
      expect(travel.local_time_field_value(:arrival_time)).to eq("2026-07-12T09:30")
      expect(travel.local_last_arrival_time.strftime("%H:%M %Z")).to eq("09:30 UTC")
      expect(travel.arrival_display).to eq("Jul 12, 2026 09:30 UTC")
    end

    it "moves a legacy row onto the event's clock the first time a time is typed again" do
      travel = legacy_travel(departure_time: Time.utc(2026, 7, 12, 6, 15), arrival_time: Time.utc(2026, 7, 12, 9, 30))

      travel.update!(arrival_time: "2026-07-12T09:45")

      travel.reload
      expect(travel.times_in_event_zone).to be(true)
      expect(travel.arrival_time).to eq(Time.utc(2026, 7, 12, 13, 45))
      # The untouched departure keeps its wall-clock, now read in New York.
      expect(travel.departure_time).to eq(Time.utc(2026, 7, 12, 10, 15))
      expect(travel.local_time_field_value(:departure_time)).to eq("2026-07-12T06:15")
    end

    it "leaves a legacy row's times alone when no time is assigned" do
      travel = legacy_travel(arrival_time: Time.utc(2026, 7, 12, 9, 30))

      travel.update!(notes: "Running late")

      travel.reload
      expect(travel.times_in_event_zone).to be(false)
      expect(travel.arrival_time).to eq(Time.utc(2026, 7, 12, 9, 30))
    end

    describe "display helpers" do
      let(:travel) do
        participant_event.travels.create!(direction: "inbound", mode: "train",
          departure_time: "2026-07-12T06:15", arrival_time: "2026-07-12T09:30")
      end

      it "returns train times on the event's clock for the first departure and last arrival" do
        expect(travel.local_first_departure_time.strftime("%Y-%m-%d %H:%M %Z")).to eq("2026-07-12 06:15 EDT")
        expect(travel.local_last_arrival_time.strftime("%Y-%m-%d %H:%M %Z")).to eq("2026-07-12 09:30 EDT")
      end

      it "labels the arrival with the event's zone" do
        travel.update!(arrival_city: "Boston")

        expect(travel.arrival_display).to eq("Jul 12, 2026 09:30 EDT - Boston")
      end

      it "files the journey on the travel calendar at the arrival instant" do
        expect(travel.calendar_time).to eq(Time.utc(2026, 7, 12, 13, 30))
      end

      it "files an inbound car journey at its expected arrival" do
        car = participant_event.travels.create!(direction: "inbound", mode: "car",
          expected_arrival_time: "2026-07-12T18:00")

        expect(car.calendar_time).to eq(Time.utc(2026, 7, 12, 22, 0))
      end
    end
  end
end
