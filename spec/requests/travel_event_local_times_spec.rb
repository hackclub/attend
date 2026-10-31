require "rails_helper"

# Train, bus and car times are typed and shown on the event's clock by every
# writer (admin, onboarding, dashboard, guardian portal). Admin inputs also
# render in 24-hour time (lang="en-GB"); participant-facing inputs don't.
# 2026-07-12 is EDT (UTC-4) in New York.
RSpec.describe "Travel times on the event's clock", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) do
    create(:event, accommodation_enabled: false, travel_enabled: true, timezone: "America/New_York")
  end
  let(:participant) { create(:participant, user: create(:user)) }
  let!(:participant_event) do
    create(:participant_event, participant: participant, event: event, status: :in_progress, onboarding_step: 1)
  end
  let(:hint) { "In the event's time zone: America/New_York." }

  def page
    Nokogiri::HTML(response.body)
  end

  def legacy_inbound_train(arrival_time:)
    travel = participant_event.travels.create!(direction: "inbound", arrangement_status: "confirmed", mode: "train",
      train_departure_station: "Penn Station", train_arrival_station: "South Station", arrival_time: arrival_time)
    travel.update_columns(times_in_event_zone: false)
    travel
  end

  def jfk_leg(travel)
    travel.travel_legs.create!(
      position: 0, flight_code: "BA112", departure_airport: "JFK", arrival_airport: "LHR",
      departure_time: Time.utc(2026, 6, 6, 1, 0), departure_time_zone: "America/New_York",
      arrival_time: Time.utc(2026, 6, 6, 8, 30), arrival_time_zone: "Europe/London"
    )
  end

  describe "admin travel page" do
    let(:admin) do
      User.create!(email: "travel-times-admin@example.com", name: "Travel Admin",
        global_role: "global_admin", admin_console_beta: false)
    end

    before { sign_in admin }

    def save_travel
      patch travel_admin_event_participant_path(event, participant_event), params: {
        travel_inbound: {
          arrangement_status: "confirmed", mode: "train",
          train_departure_station: "Penn Station", train_arrival_station: "South Station",
          arrival_time: "2026-07-12T09:30"
        },
        travel_outbound: { arrangement_status: "provisional", mode: "bus", departure_time: "2026-07-14T17:00" }
      }
    end

    it "saves typed times on the event's clock" do
      save_travel

      expect(response).to redirect_to(travel_admin_event_participant_path(event, participant_event))
      participant_event.reload
      expect(participant_event.travel_inbound).to have_attributes(
        arrival_time: Time.utc(2026, 7, 12, 13, 30), times_in_event_zone: true
      )
      expect(participant_event.travel_outbound.departure_time).to eq(Time.utc(2026, 7, 14, 21, 0))
    end

    it "prefills the event-local time in a 24-hour input with the zone hint" do
      save_travel
      get travel_admin_event_participant_path(event, participant_event)

      input = page.at('input[name="travel_inbound[arrival_time]"]')
      expect(input["value"]).to eq("2026-07-12T09:30")
      expect(input["lang"]).to eq("en-GB")
      expect(page.at('input[name="travel_outbound[departure_time]"]')["value"]).to eq("2026-07-14T17:00")
      expect(response.body).to include(hint)
    end

    it "does the same in the console" do
      admin.update!(admin_console_beta: true)
      save_travel
      get travel_admin_event_participant_path(event, participant_event)

      input = page.at('input[name="travel_inbound[arrival_time]"]')
      expect(input["value"]).to eq("2026-07-12T09:30")
      expect(input["lang"]).to eq("en-GB")
      description = page.at("##{input["aria-describedby"].split.find { |id| id.end_with?("-description") }}")
      expect(description.text).to include(hint)
    end

    it "prefills a legacy row as it was typed and reads a re-save on the event's clock" do
      travel = legacy_inbound_train(arrival_time: Time.utc(2026, 7, 12, 9, 30))

      get travel_admin_event_participant_path(event, participant_event)
      expect(page.at('input[name="travel_inbound[arrival_time]"]')["value"]).to eq("2026-07-12T09:30")

      save_travel
      expect(travel.reload).to have_attributes(arrival_time: Time.utc(2026, 7, 12, 13, 30), times_in_event_zone: true)
    end

    [ false, true ].each do |console|
      it "renders flight leg times in 24-hour inputs#{" in the console" if console}" do
        admin.update!(admin_console_beta: console)
        jfk_leg(participant_event.travels.create!(direction: "inbound", mode: "plane"))

        get travel_admin_event_participant_path(event, participant_event)

        leg_inputs = page.css('input[type="datetime-local"][name^="travel_inbound[travel_legs_attributes]"]')
        expect(leg_inputs.size).to eq(2)
        expect(leg_inputs.map { |input| input["lang"] }).to all(eq("en-GB"))
        template_inputs = page.css("template#leg-template input[type='datetime-local']")
        expect(template_inputs.size).to eq(2)
        expect(template_inputs.map { |input| input["lang"] }).to all(eq("en-GB"))
      end
    end

    describe "participant page" do
      it "shows times on the event's clock, and a legacy row on UTC" do
        participant_event.travels.create!(direction: "outbound", mode: "bus", departure_time: "2026-07-14T17:00")
        legacy_inbound_train(arrival_time: Time.utc(2026, 7, 12, 9, 30))

        get admin_event_participant_path(event, participant_event)

        expect(response.body).to include("Jul 14, 2026 17:00 EDT")
        expect(response.body).to include("Jul 12, 2026 09:30 UTC")
      end

      it "shows times on the event's clock in the console" do
        admin.update!(admin_console_beta: true)
        participant_event.travels.create!(direction: "outbound", mode: "bus", departure_time: "2026-07-14T17:00")
        legacy_inbound_train(arrival_time: Time.utc(2026, 7, 12, 9, 30))

        get admin_event_participant_path(event, participant_event)

        datetimes = page.css("time").map { |time| time["datetime"] }
        expect(datetimes).to include("2026-07-14T17:00:00-04:00")
        expect(datetimes).to include("2026-07-12T09:30:00Z")
      end
    end
  end

  describe "participant dashboard" do
    before { sign_in participant.user }

    it "saves typed times on the event's clock and shows them back as typed" do
      patch dashboard_event_travel_path(participant_event), params: {
        travel_inbound: {
          arrangement_status: "confirmed", mode: "bus",
          bus_departure_location: "New York", bus_arrival_location: "Boston",
          departure_time: "2026-07-12T06:15", arrival_time: "2026-07-12T09:30"
        },
        travel_outbound: { arrangement_status: "provisional", mode: "car", departure_time: "2026-07-14T17:00" }
      }

      expect(response).to redirect_to(dashboard_event_path(participant_event))
      inbound = participant_event.reload.travel_inbound
      expect(inbound).to have_attributes(
        departure_time: Time.utc(2026, 7, 12, 10, 15), arrival_time: Time.utc(2026, 7, 12, 13, 30)
      )

      get dashboard_event_travel_edit_path(participant_event)
      expect(page.css('input[name="travel_inbound[arrival_time]"]').map { |input| input["value"] }.uniq)
        .to eq([ "2026-07-12T09:30" ])
      expect(page.css('input[name="travel_outbound[departure_time]"]').map { |input| input["value"] }.uniq)
        .to eq([ "2026-07-14T17:00" ])
      expect(page.css('input[type="datetime-local"][lang]')).to be_empty

      get dashboard_event_path(participant_event)
      expect(response.body).to include("Jul 12 · 09:30")
    end
  end

  describe "onboarding travel step" do
    before { sign_in participant.user }

    it "prefills times on the event's clock and leaves flight leg inputs in the browser's format" do
      participant_event.travels.create!(direction: "outbound", mode: "train", departure_time: "2026-07-14T17:00")
      jfk_leg(participant_event.travels.create!(direction: "inbound", mode: "plane"))

      get onboarding_step_path(step: "travel", event_id: event.id)

      expect(page.css('input[name="travel_outbound[departure_time]"]').map { |input| input["value"] }.uniq)
        .to eq([ "2026-07-14T17:00" ])
      expect(page.at('input[name="travel_inbound[travel_legs_attributes][0][departure_time]"]')["value"])
        .to eq("2026-06-05T21:00")
      expect(page.css('input[type="datetime-local"][lang]')).to be_empty
    end
  end
end
