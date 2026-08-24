require "rails_helper"

RSpec.describe "Admin::TravelCalendar", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-travel-calendar@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event, timezone: "America/Los_Angeles") }

  before { sign_in admin }

  describe "GET /admin/events/:slug/travel" do
    def create_journey(mode:, direction:, participant_event: nil, **attributes)
      participant_event ||= create(:participant_event, event: event, status: :complete)
      Travel.create!(participant_event: participant_event, mode: mode, direction: direction, **attributes)
    end

    it "renders every travel mode in one day-grouped agenda" do
      checked_in_registration = create(:participant_event, :checked_in, event: event, status: :complete)
      create_journey(mode: "train", direction: "inbound", participant_event: checked_in_registration, arrival_time: Time.utc(2026, 8, 24, 17), train_departure_station: "Oakland", train_arrival_station: "San Francisco", carrier: "Amtrak")
      plane = create_journey(mode: "plane", direction: "inbound")
      create(:travel_leg, travel: plane, departure_time: Time.utc(2026, 8, 24, 15), arrival_time: Time.utc(2026, 8, 24, 19), departure_airport: "JFK", arrival_airport: "SFO", flight_code: "UA123")
      create_journey(mode: "bus", direction: "outbound", departure_time: Time.utc(2026, 8, 25, 18), bus_departure_location: "Venue", bus_arrival_location: "SFO", carrier: "Event shuttle")
      create_journey(mode: "car", direction: "inbound", expected_arrival_time: Time.utc(2026, 8, 25, 20), origin_address: "Oakland")
      create_journey(mode: "other", direction: "outbound", other_details: "Collected by guardian")

      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Travel Calendar")
      expect(response.body).to include(event.name)
      expect(response.body).to include("Monday 24 August")
      expect(response.body).to include("Tuesday 25 August")
      expect(response.body).to include("Unscheduled")
      expect(response.body).to include("Train", "Bus", "Car", "Flight", "Other")
      expect(response.body).to include("Awaiting pickup", "Checked in")
      expect(response.body).not_to include("Terminal", "Gate", "Refresh status")

      document = Nokogiri::HTML(response.body)
      expect(document.css("nav[aria-label='Travel filters']").size).to eq(1)
      expect(document.css("[data-travel-calendar-filter-target~='day'] [data-travel-calendar-filter-target~='count']").map(&:text).map(&:strip)).to eq([ "2 journeys", "2 journeys", "1 journey" ])
      rows = document.css("section[data-travel-calendar-filter-target~='day'] ol > li[data-travel-calendar-filter-target~='entry']")
      expect(rows.size).to eq(5)
      expect(document.css("li[data-travel-calendar-filter-target~='entry'] > details").size).to eq(5)

      rows_by_mode = rows.index_by { |row| row["data-travel-calendar-filter-mode-value"] }
      expect(rows_by_mode.fetch("train").attributes).to include(
        "data-travel-calendar-filter-direction-value" => have_attributes(value: "inbound"),
        "data-travel-calendar-filter-pickup-value" => have_attributes(value: "checked_in")
      )
      expect(rows_by_mode.fetch("bus")["data-travel-calendar-filter-pickup-value"]).to eq("")
      expect(rows_by_mode.fetch("plane")["data-travel-calendar-filter-search-value"]).to include("ua123", "jfk", "sfo")
    end

    it "renders one hidden live status for dynamic no-results feedback" do
      create_journey(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17))

      get "/admin/events/#{event.slug}/travel"

      statuses = Nokogiri::HTML(response.body).css("[data-travel-calendar-filter-target~='empty']")
      expect(statuses.size).to eq(1)
      expect(statuses.first.attributes).to include(
        "role" => have_attributes(value: "status"),
        "aria-live" => have_attributes(value: "polite"),
        "aria-atomic" => have_attributes(value: "true")
      )
      expect(statuses.first).to have_attribute("hidden")
      expect(statuses.first.text.strip).to eq("No journeys match these filters.")
    end

    it "renders an empty-calendar explanation" do
      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No travel has been scheduled yet.")
    end

    it "renders the effective event timezone for valid, blank, and invalid values" do
      {
        "America/Los_Angeles" => "America/Los_Angeles",
        "" => "Etc/UTC",
        "Not/A_Timezone" => "Etc/UTC"
      }.each do |stored_timezone, expected_label|
        event.update_column(:timezone, stored_timezone)

        get "/admin/events/#{event.slug}/travel"

        expect(response).to have_http_status(:ok)
        context = Nokogiri::HTML(response.body).at_css("header p")&.text&.squish
        expect(context).to eq("#{event.name} · times in #{expected_label}")
        expect(context).not_to end_with("times in")
      end
    end

    it "renders a neutral fallback when travel mode is not provided" do
      create_journey(mode: nil, direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17))

      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      row = Nokogiri::HTML(response.body).at_css("li[data-travel-calendar-filter-target~='entry']")
      expect(row.text).to include("Mode not provided")
      expect(row["data-travel-calendar-filter-mode-value"]).to eq("")
    end

    it "renders participant headshots without per-row attachment queries" do
      png = file_fixture("headshot.png").binread
      participant_events = 2.times.map do |index|
        participant = create(:participant, legal_first_name: "Photo#{index}", legal_last_name: "Person")
        participant.headshot.attach(io: StringIO.new(png), filename: "headshot-#{index}.png", content_type: "image/png")
        create(:participant_event, event: event, participant: participant, status: :complete)
      end
      participant_events.each_with_index do |participant_event, index|
        create_journey(mode: "train", direction: "inbound", participant_event: participant_event, arrival_time: Time.utc(2026, 8, 24, 17 + index))
      end
      headshot_blob_ids = participant_events.map { |participant_event| participant_event.participant.headshot.blob_id }

      active_storage_queries = []
      subscriber = lambda do |*, payload|
        sql = payload[:sql]
        if sql.include?("active_storage_attachments") || sql.include?("active_storage_blobs")
          active_storage_queries << [ sql, payload[:binds].map { |bind| bind.value_for_database } ]
        end
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get "/admin/events/#{event.slug}/travel"
      end

      expect(response).to have_http_status(:ok)
      rows = Nokogiri::HTML(response.body).css("li[data-travel-calendar-filter-target~='entry']")
      expect(rows.map { |row| row.at_css("img")&.[]("alt") }).to eq([ "", "" ])
      headshot_attachment_queries = active_storage_queries.select { |sql, binds| sql.include?("active_storage_attachments") && binds.include?("headshot") }
      headshot_blob_queries = active_storage_queries.select { |sql, binds| sql.include?("active_storage_blobs") && (headshot_blob_ids - binds).empty? }
      expect(headshot_attachment_queries.size).to eq(1), active_storage_queries.inspect
      expect(headshot_blob_queries.size).to eq(1), active_storage_queries.inspect
    end

    it "keeps the filters below the mobile admin header while scrolling" do
      create_journey(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17))

      get "/admin/events/#{event.slug}/travel"

      nav = Nokogiri::HTML(response.body).at_css("nav[aria-label='Travel filters']")
      expect(nav["class"].split).to include("sticky", "top-12", "lg:top-0", "z-20", "bg-(--bg-elev-2)")
    end

    it "indexes free-form travel details for client-side search" do
      create_journey(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17), notes: "Call the midnight duty phone")

      get "/admin/events/#{event.slug}/travel"

      row = Nokogiri::HTML(response.body).at_css("li[data-travel-calendar-filter-target~='entry']")
      expect(row["data-travel-calendar-filter-search-value"]).to include("call the midnight duty phone")
    end

    it "keeps a plane journey without legs informative while collapsed" do
      create_journey(mode: "plane", direction: "outbound")

      get "/admin/events/#{event.slug}/travel"

      expect(response).to have_http_status(:ok)
      row = Nokogiri::HTML(response.body).at_css("li[data-travel-calendar-filter-mode-value='plane']")
      collapsed_content = row.xpath("./div").first
      expect(collapsed_content.text).to include("Flight", "Details not provided")
    end

    it "uses mode-specific labels for travel references" do
      plane = create_journey(mode: "plane", direction: "inbound")
      create(:travel_leg, travel: plane, departure_time: Time.utc(2026, 8, 24, 15), arrival_time: Time.utc(2026, 8, 24, 19), departure_airport: "JFK", arrival_airport: "SFO", flight_code: "UA123")
      create_journey(mode: "train", direction: "inbound", arrival_time: Time.utc(2026, 8, 24, 17), train_departure_station: "Oakland", train_arrival_station: "San Francisco", carrier: "Amtrak")

      get "/admin/events/#{event.slug}/travel"

      rows_by_mode = Nokogiri::HTML(response.body).css("li[data-travel-calendar-filter-target~='entry']").index_by { |row| row["data-travel-calendar-filter-mode-value"] }
      plane_row = rows_by_mode.fetch("plane")
      train_row = rows_by_mode.fetch("train")
      expect(plane_row.xpath("./div").first.text).to include("Flight code: UA123")
      expect(train_row.xpath("./div").first.text).to include("Carrier: Amtrak")
      expect(plane_row.css("dt").map(&:text)).to include("Flight code")
      expect(train_row.css("dt").map(&:text)).to include("Carrier")
    end

    it "redirects to the event dashboard when travel is disabled" do
      event.update!(travel_enabled: false)

      get "/admin/events/#{event.slug}/travel"

      expect(response).to redirect_to(admin_event_dashboard_path(event.slug))
      follow_redirect!
      expect(response.body).to include("Travel is disabled for this event.")
    end

    it "renders controls that support the canonical query contract" do
      event.update!(groups_enabled: true)
      group = create(:group, event: event, name: "Alex group")
      participant = create(:participant, preferred_name: "Alex")
      participant_event = create(:participant_event, event: event, participant: participant, status: :complete)
      travel = create_journey(mode: "plane", direction: "inbound", participant_event: participant_event)
      create(:travel_leg, travel: travel, departure_airport: "JFK", arrival_airport: "SFO")

      get admin_event_travel_path(event), params: {
        direction: "inbound",
        mode: "plane",
        group: group.id,
        pickup: "awaiting_pickup",
        search: "alex"
      }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-controller~='travel-calendar-filter']")).to be_present
      expect(document.css("select[data-travel-calendar-filter-target='direction'] option").map { |option| option["value"] }).to include("inbound")
      expect(document.css("select[data-travel-calendar-filter-target='mode'] option").map { |option| option["value"] }).to include("plane")
      expect(document.css("select[data-travel-calendar-filter-target='pickup'] option").map { |option| option["value"] }).to include("awaiting_pickup")
      expect(document.css("select[data-travel-calendar-filter-target='group'] option").map { |option| option["value"] }).to include(group.id)
    end

    it "translates legacy query keys while preserving other filters" do
      get "/admin/events/#{event.slug}/airport_mode", params: {
        tab: "outbound",
        group_id: "legacy-group",
        mode: "plane",
        search: "alex",
        page: "2"
      }

      expect(response).to have_http_status(:found)
      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      expect(URI.parse(response.location).path).to eq(admin_event_travel_path(event))
      expect(query).to eq(
        "direction" => "outbound",
        "group" => "legacy-group",
        "mode" => "plane",
        "search" => "alex",
        "page" => "2"
      )
    end

    it "prefers canonical query keys when legacy keys conflict" do
      get "/admin/events/#{event.slug}/airport_mode", params: {
        tab: "outbound",
        direction: "inbound",
        group_id: "legacy-group",
        group: "canonical-group",
        pickup: "collected",
        source: "operations"
      }

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      expect(query).to include(
        "direction" => "inbound",
        "group" => "canonical-group",
        "pickup" => "collected",
        "source" => "operations"
      )
      expect(query).not_to include("tab", "group_id")
    end

    it "preserves blank canonical keys when legacy keys conflict" do
      get "/admin/events/#{event.slug}/airport_mode", params: {
        tab: "outbound",
        direction: "",
        group_id: "legacy-group",
        group: "",
        search: "alex"
      }

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      expect(query).to include(
        "direction" => "",
        "group" => "",
        "search" => "alex"
      )
      expect(query).not_to include("tab", "group_id")
    end

    it "marks the sidebar link active only on the canonical travel calendar path" do
      get admin_event_travel_path(event)

      calendar_links = Nokogiri::HTML(response.body).css("a").select { |link| link.text.strip == "Travel Calendar" }
      expect(calendar_links).not_to be_empty
      expect(calendar_links).to all(satisfy { |link| link["class"].split.include?("nav-item-active") })

      participant_event = create(:participant_event, event: event)
      get travel_admin_event_participant_path(event, participant_event)

      calendar_links = Nokogiri::HTML(response.body).css("a").select { |link| link.text.strip == "Travel Calendar" }
      expect(calendar_links).not_to be_empty
      expect(calendar_links).to all(satisfy { |link| link["class"].split.exclude?("nav-item-active") })
    end
  end

  describe "POST /admin/events/:slug/travel/dismiss_pickup" do
    it "rejects outbound travel for the current event without mutation" do
      participant_event = create(:participant_event, event: event, status: :complete)
      outbound = Travel.create!(
        participant_event: participant_event,
        direction: "outbound",
        mode: "bus"
      )

      post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: outbound.id }

      expect(response).to have_http_status(:not_found)
      expect(outbound.reload.pickup_dismissed_at).to be_nil
      expect(outbound).not_to be_pickup_dismissed
    end

    it "rejects dismissal for another event's travel" do
      other_event = create(:event)
      other_participant_event = create(:participant_event, event: other_event, status: :complete)
      other_event_travel = Travel.create!(
        participant_event: other_participant_event,
        direction: "inbound",
        mode: "bus"
      )

      post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: other_event_travel.id }

      expect(response).to have_http_status(:not_found)
      expect(other_event_travel.reload).not_to be_pickup_dismissed
    end

    it "invalidates the cached pickup state after dismissal" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "bus")

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post dismiss_pickup_admin_event_travel_path(event), params: { travel_id: travel.id }

      expect(response).to redirect_to(admin_event_travel_path(event))
      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:pickup_not_needed)
    end
  end

  describe "POST /admin/events/:slug/scans" do
    it "invalidates the cached pickup state after venue check-in" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      participant_event = create(:participant_event, event: event, status: :complete)
      travel = Travel.create!(participant_event: participant_event, direction: "inbound", mode: "train")
      check_in = event.scan_contexts.find_by!(checks_in: true)

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      post admin_event_scans_path(event), params: {
        participant_id: participant_event.participant_id,
        scan_context_id: check_in.id
      }

      expect(response).to have_http_status(:ok)
      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :checked_in)
    end
  end
end
