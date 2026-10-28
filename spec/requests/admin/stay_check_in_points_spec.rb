require "rails_helper"

# Every stay gets its own lodging scan point, and its arrival numbers count
# only the people with a room in that stay: when everyone who has a room for
# the night before has been scanned in at the hotel, it reads 100%.
RSpec.describe "Stay check-in points", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }
  let(:event) { create(:event, nfc_badges_enabled: false) }

  before { sign_in admin }

  def roomed_in(stay, room)
    create(:participant_event, event: event, status: :complete).tap do |pe|
      pe.create_accommodation!
      RoomAssignment.create!(room: room, participant_event: pe)
    end
  end

  describe "creating a stay" do
    it "creates a lodging scan point named after it" do
      stay = event.rooming_contexts.create!(name: "Night before", kind: :pre_event)

      point = stay.scan_context
      expect(point).to be_lodging
      expect(point.name).to eq("Night before arrivals")
      expect(point.rooming_context).to eq(stay)
      expect(event.reload.hotel_scan_context).to be_nil
    end

    it "makes the stay during the event's point the event's hotel point when it has none" do
      stay = event.main_rooming_context

      expect(event.reload.hotel_scan_context).to eq(stay.scan_context)
    end

    it "adopts an existing hotel point for the stay during the event" do
      hotel = event.scan_contexts.create!(name: "Hotel lobby", kind: "lodging")
      event.update!(hotel_scan_context: hotel)

      expect { event.main_rooming_context }.not_to change(ScanContext, :count)
      expect(event.main_rooming_context.scan_context).to eq(hotel)
    end

    it "renames the point with the stay, unless someone renamed it" do
      stay = event.rooming_contexts.create!(name: "Night before", kind: :pre_event)

      stay.update!(name: "Friday night")
      expect(stay.scan_context.reload.name).to eq("Friday night arrivals")

      stay.scan_context.update!(name: "Lobby desk")
      stay.update!(name: "Thursday night")
      expect(stay.scan_context.reload.name).to eq("Lobby desk")
    end
  end

  describe "removing a stay" do
    let!(:stay) { event.rooming_contexts.create!(name: "Night after", kind: :post_event) }

    it "removes a point nobody was scanned at" do
      point = stay.scan_context

      delete admin_event_rooming_stay_path(event.slug, stay)

      expect(ScanContext.exists?(point.id)).to be(false)
    end

    it "keeps a point with scans, for the record" do
      point = stay.scan_context
      pe = create(:participant_event, event: event)
      pe.scans.create!(scan_context: point, user: admin, scanned_at: Time.current, source: "qr")

      delete admin_event_rooming_stay_path(event.slug, stay)

      expect(ScanContext.exists?(point.id)).to be(true)
    end
  end

  it "adds a check-in point to a stay that predates them" do
    stay = event.rooming_contexts.create!(name: "Night after", kind: :post_event)
    stay.scan_context.destroy!
    stay.reload

    post add_check_in_point_admin_event_rooming_stay_path(event.slug, stay)

    expect(stay.reload.scan_context).to be_lodging
    expect(response).to redirect_to(admin_event_rooming_stays_path(event.slug))
  end

  describe "arrival numbers" do
    let(:stay) { event.rooming_contexts.create!(name: "Night before", kind: :pre_event, enrollment: :everyone) }
    let(:room) { stay.rooms.create!(name: "101", capacity: 3) }
    let!(:arrived) { roomed_in(stay, room) }
    let!(:waiting) { roomed_in(stay, room) }
    let!(:no_room) { create(:participant_event, event: event, status: :complete) }

    before do
      [ arrived, no_room ].each do |pe|
        pe.scans.create!(scan_context: stay.scan_context, user: admin, scanned_at: Time.current, source: "qr")
      end
    end

    it "counts only people with a room in the stay" do
      expect(stay.expected_count).to eq(2)
      expect(stay.arrived_count).to eq(1)
    end

    { "in the original admin" => false, "with the admin console beta" => true }.each do |ui, console|
      it "shows them on the check-ins page #{ui}" do
        admin.update!(admin_console_beta: console)

        get admin_event_scans_path(event)

        text = Nokogiri::HTML5(response.body).text.squish
        expect(text).to include("1 of 2 people with a room in Night before arrived · 50%")
      end

      it "shows them on the accommodation page #{ui}" do
        admin.update!(admin_console_beta: console)

        get admin_event_rooming_stays_path(event.slug)

        expect(Nokogiri::HTML5(response.body).text.squish).to include("1 of 2 at Night before arrivals")
      end
    end

    it "tells the scanner the room, or that there isn't one" do
      post admin_event_scans_path(event), params: { participant_id: waiting.id, scan_context_id: stay.scan_context.id }, as: :json
      expect(response.parsed_body["stay"]).to eq("name" => "Night before", "room" => "101")

      post admin_event_scans_path(event), params: { participant_id: no_room.id, scan_context_id: stay.scan_context.id }, as: :json
      expect(response.parsed_body["stay"]).to eq("name" => "Night before", "room" => nil)
    end

    it "says nothing about stays at other scan points" do
      venue = event.scan_contexts.find_by!(checks_in: true)

      post admin_event_scans_path(event), params: { participant_id: waiting.id, scan_context_id: venue.id }, as: :json

      expect(response.parsed_body["stay"]).to be_nil
    end
  end
end
