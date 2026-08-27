require "rails_helper"

# The Limited event role does everything Ops does, minus a participant's exact
# date of birth and any address -- home or travel pickup. Medical records are
# deliberately full: the role has to be able to help in an incident. These specs
# pin the redaction on every surface that renders or exports a restricted field.
RSpec.describe "Limited event role", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event, accommodation_enabled: false) }
  let(:participant) do
    create(:participant,
      legal_first_name: "Dorothy", legal_last_name: "Vaughan",
      date_of_birth: Date.new(2009, 3, 14),
      address_line_1: "12 Langley Road", city: "Hampton", state: "VA",
      postal_code: "23666", country_of_residence: "USA")
  end
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }

  def sign_in_with_role(role, email: "#{role}-limited-spec@example.com")
    user = User.create!(email: email, name: role.titleize)
    EventRoleAssignment.create!(user: user, event: event, role: role)
    sign_in user
    user
  end

  describe "the participant profile" do
    it "shows age but not the exact date of birth or address" do
      sign_in_with_role("limited")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Age at Event")
      expect(response.body).not_to include("Date of Birth", "March 14, 2009")
      expect(response.body).not_to include("12 Langley Road", "23666")
    end

    it "still shows both to ops" do
      sign_in_with_role("ops")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include("Date of Birth", "March 14, 2009")
      expect(response.body).to include("12 Langley Road", "23666")
    end
  end

  describe "the participant table" do
    it "drops the DOB column" do
      sign_in_with_role("limited")

      get table_admin_event_participants_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(">Age<")
      expect(response.body).not_to include('data-column="dob"', "2009-03-14")
    end
  end

  describe "the edit form" do
    it "omits the date of birth field and ignores it when posted" do
      sign_in_with_role("limited")

      get edit_admin_event_participant_path(event.slug, participant_event)
      expect(response.body).not_to include("participant[date_of_birth]")

      patch admin_event_participant_path(event.slug, participant_event),
        params: { participant: { preferred_name: "Dot", date_of_birth: "1990-01-01" } }

      expect(participant.reload.preferred_name).to eq("Dot")
      expect(participant.date_of_birth).to eq(Date.new(2009, 3, 14))
    end
  end

  describe "the change history" do
    it "hides date of birth and address changes" do
      PaperTrail.request(whodunnit: nil) { participant.update!(date_of_birth: Date.new(2008, 1, 2), city: "Newport") }
      sign_in_with_role("limited")

      get history_admin_event_participant_path(event.slug, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("2008-01-02", "Newport")
    end
  end

  describe "exports" do
    it "does not offer the DOB or address columns" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("participant.age_at_event", "travel.inbound.mode")
      expect(response.body).not_to include("participant.date_of_birth", "participant.address_line_1",
        "participant.postal_code")
    end

    it "still offers the participants preset, stripping the DOB column from it" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)
      expect(response.body).to include("preset=participants")

      get admin_event_exports_path(event_slug: event.slug, preset: "participants")
      expect(response.body).to include("not authorized to export", "Date of Birth")
      expect(response.body).not_to include("participant.date_of_birth")
    end

    it "describes the Participant category without promising an address" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)

      expect(response.body).to include("Contact details and profile information")
      expect(response.body).not_to include("Contact details, address, and profile information")
    end

    it "refuses an export that asks for them anyway" do
      sign_in_with_role("limited")

      post admin_event_exports_path(event_slug: event.slug),
        params: { columns: [ "participant.email", "participant.date_of_birth" ], row_mode: "participant" }

      expect(response).to redirect_to(admin_event_exports_path(event.slug))
      expect(flash[:alert]).to include("not authorized to export", "Date of Birth")
    end
  end

  describe "the rooming sheet" do
    it "leaves the date of birth column out of the CSV" do
      room = event.rooms.create!(name: "101", capacity: 2)
      room.room_assignments.create!(participant_event: participant_event)
      sign_in_with_role("limited")

      get export_csv_admin_event_rooming_wizard_path(event.slug, format: :csv)

      expect(response).to have_http_status(:ok)
      expect(response.body.lines.first).to include("Age at Event")
      expect(response.body).not_to include("Date of Birth", "2009-03-14")
    end
  end

  describe "travel pickup addresses" do
    let!(:travel) do
      participant_event.travels.create!(direction: "inbound", mode: "car",
        origin_address: "12 Langley Road, Hampton VA", expected_arrival_time: 1.week.from_now)
    end

    it "hides the address on the participant profile" do
      sign_in_with_role("limited")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include("Address hidden")
      expect(response.body).not_to include("12 Langley Road")
    end

    it "omits the field from the travel form and ignores it when posted" do
      sign_in_with_role("limited")

      get travel_admin_event_participant_path(event.slug, participant_event)
      expect(response.body).not_to include("travel_inbound[origin_address]")

      patch travel_admin_event_participant_path(event.slug, participant_event),
        params: { travel_inbound: { mode: "car", origin_address: "" } }

      expect(travel.reload.origin_address).to eq("12 Langley Road, Hampton VA")
    end

    it "replaces the car route on the travel calendar" do
      participant_event.update!(status: "complete")
      TravelCalendar::JourneyCache.clear(event)
      sign_in_with_role("limited")

      get admin_event_travel_path(event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Address hidden")
      expect(response.body).not_to include("12 Langley Road")
    end

    it "leaves the calendar route intact for ops" do
      participant_event.update!(status: "complete")
      TravelCalendar::JourneyCache.clear(event)
      sign_in_with_role("ops")

      get admin_event_travel_path(event.slug)

      expect(response.body).to include("12 Langley Road")
    end

    it "does not offer the origin address export columns" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)

      expect(response.body).to include("travel.inbound.mode")
      expect(response.body).not_to include("travel.inbound.origin_address",
        "travel.outbound.origin_address")
    end
  end

  describe "medical records" do
    it "gets the full clinical detail, not the trimmed ops view" do
      user = sign_in_with_role("limited")
      medical = participant_event.create_medical!(medical_conditions: "Type 1 diabetes",
        medications: "Insulin", allergies: "Peanuts")

      Current.event = event
      expect(MedicalPolicy.new(user, medical).show_full_details?).to be(true)

      get medical_admin_event_participant_path(event.slug, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Type 1 diabetes", "Insulin")
    end
  end

  describe "the participants API" do
    let(:limited_user) { User.create!(email: "limited-api@example.com", name: "Limited") }
    let(:token) { MobileToken.generate_for(limited_user) }

    before do
      EventRoleAssignment.create!(user: limited_user, event: event, role: "limited")
      participant_event.travels.create!(direction: "inbound", mode: "car",
        origin_address: "12 Langley Road, Hampton VA")
    end

    def show_payload
      get api_v1_event_participant_path(event_id: event.slug, id: participant_event.id),
        headers: { "Authorization" => "Bearer #{token.token}" }
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)["participant"]
    end

    it "serves the payload with age but no date of birth or address" do
      personal = show_payload["personal"]

      expect(personal["age"]).to be_present
      expect(personal).not_to have_key("date_of_birth")
      expect(personal).not_to have_key("address")
    end

    it "omits the travel pickup address" do
      travel = show_payload["travel_inbound"]

      expect(travel["mode"]).to eq("car")
      expect(travel).not_to have_key("origin_address")
    end

    it "leaves both in place for ops" do
      ops = User.create!(email: "ops-api@example.com", name: "Ops")
      EventRoleAssignment.create!(user: ops, event: event, role: "ops")
      ops_token = MobileToken.generate_for(ops)

      get api_v1_event_participant_path(event_id: event.slug, id: participant_event.id),
        headers: { "Authorization" => "Bearer #{ops_token.token}" }

      payload = JSON.parse(response.body)["participant"]
      expect(payload["personal"]["date_of_birth"]).to eq("2009-03-14")
      expect(payload["travel_inbound"]["origin_address"]).to eq("12 Langley Road, Hampton VA")
    end

    it "still refuses read_only entirely, with a 403 rather than a 500" do
      read_only = User.create!(email: "readonly-api@example.com", name: "Read Only")
      EventRoleAssignment.create!(user: read_only, event: event, role: "read_only")

      get api_v1_event_participants_path(event_id: event.slug),
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(read_only).token}" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the events API" do
    it "reports the role and the PII capability so the app can adapt up front" do
      EventRoleAssignment.create!(user: (u = User.create!(email: "limited-events@example.com", name: "L")),
        event: event, role: "limited")

      get api_v1_events_path, headers: { "Authorization" => "Bearer #{MobileToken.generate_for(u).token}" }

      expect(response).to have_http_status(:ok)
      payload = JSON.parse(response.body)["events"].find { |e| e["id"] == event.id }
      expect(payload["role"]).to eq("limited")
      expect(payload["can_view_participant_pii"]).to be(false)
    end

    it "reports the widest role when someone holds several, and restores PII" do
      u = User.create!(email: "multi-events@example.com", name: "M")
      EventRoleAssignment.create!(user: u, event: event, role: "limited")
      EventRoleAssignment.create!(user: u, event: event, role: "event_admin")

      get api_v1_events_path, headers: { "Authorization" => "Bearer #{MobileToken.generate_for(u).token}" }

      payload = JSON.parse(response.body)["events"].find { |e| e["id"] == event.id }
      expect(payload["role"]).to eq("event_admin")
      expect(payload["can_view_participant_pii"]).to be(true)
    end

    # Series membership outranks a stored role, so someone who is Limited on the
    # event but also a series member gets the full view and is labelled as such.
    # (An index quirk keeps series-only members out of this list entirely — see
    # EventsController#index, which uses assigned_events rather than the scope
    # EventPolicy uses.)
    it "labels inherited access without pretending it is a stored role" do
      series = create(:event_series)
      event.update!(event_series: series)
      u = User.create!(email: "series-events@example.com", name: "S")
      EventRoleAssignment.create!(user: u, event: event, role: "limited")
      SeriesRoleAssignment.create!(user: u, event_series: series, role: "organizer")

      get api_v1_events_path, headers: { "Authorization" => "Bearer #{MobileToken.generate_for(u).token}" }

      payload = JSON.parse(response.body)["events"].find { |e| e["id"] == event.id }
      expect(payload["role"]).to eq("series_member")
      expect(payload["can_view_participant_pii"]).to be(true)
    end
  end
end
