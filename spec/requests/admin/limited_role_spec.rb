require "rails_helper"

# The Limited event role does everything Ops does, minus a participant's exact
# date of birth, any address (home or travel pickup), every phone number, and
# the contact details of the people around them (guardians, emergency contacts).
# Two things stay: the attendee's own email address, which the role searches and
# works from, and an emergency contact's first name and phone number, which
# running an incident depends on. Medical records are deliberately full for the
# same reason. These specs pin the redaction on every surface that renders or
# exports a restricted field.
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

    it "hides the phone number but keeps the attendee's email" do
      participant.update!(phone: "+15005550001")
      sign_in_with_role("limited")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include(participant.email)
      expect(response.body).not_to include("+15005550001")
    end

    it "still shows the phone number to ops" do
      participant.update!(phone: "+15005550001")
      sign_in_with_role("ops", email: "ops-contact-spec@example.com")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include(participant.email, "+15005550001")
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

    it "drops the phone column and keeps the email one" do
      participant.update!(phone: "+15005550001")
      sign_in_with_role("limited")

      get table_admin_event_participants_path(event.slug)

      expect(response.body).to include('data-column="email"', participant.email)
      expect(response.body).not_to include('data-column="phone"', "+15005550001")
    end

    it "still filters by email, which is how the role finds people" do
      participant.update!(email: "dorothy@example.com")
      other = create(:participant, legal_first_name: "Mary", legal_last_name: "Jackson",
        email: "mary@example.com")
      create(:participant_event, event: event, participant: other)
      sign_in_with_role("limited")

      get table_admin_event_participants_path(event.slug,
        filters: { "0" => { field: "email", operator: "starts_with", value: "dorothy" } })

      expect(response.body).to include("Dorothy")
      expect(response.body).not_to include("Mary")
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

    it "omits the phone field and ignores it when posted, but still edits email" do
      participant.update!(phone: "+15005550001")
      sign_in_with_role("limited")

      get edit_admin_event_participant_path(event.slug, participant_event)
      expect(response.body).to include("participant[email]")
      expect(response.body).not_to include("participant[phone]")

      patch admin_event_participant_path(event.slug, participant_event),
        params: { participant: { preferred_name: "Dot", email: "elsewhere@example.com", phone: "+15005550009" } }

      expect(participant.reload.email).to eq("elsewhere@example.com")
      expect(participant.phone).to eq("+15005550001")
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

    it "hides phone changes, and a guardian's email, but not the attendee's own" do
      guardian = Guardian.create!(legal_first_name: "Katherine", legal_last_name: "Johnson",
        email: "katherine-history@example.com", phone: "+15005550003")
      participant_event.guardian_participant_events.create!(guardian: guardian, relationship: "Parent")
      PaperTrail.request(whodunnit: nil) do
        participant.update!(email: "moved@example.com", phone: "+15005550004")
        guardian.update!(email: "katherine-new@example.com")
      end
      sign_in_with_role("limited")

      get history_admin_event_participant_path(event.slug, participant_event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("moved@example.com")
      expect(response.body).not_to include("+15005550004", "katherine-new@example.com")
    end
  end

  describe "exports" do
    it "does not offer the DOB, address, or phone columns, but keeps email" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("participant.age_at_event", "travel.inbound.mode",
        "participant.email")
      expect(response.body).not_to include("participant.date_of_birth", "participant.address_line_1",
        "participant.postal_code", "participant.phone")
    end

    it "still offers the participants preset, stripping the DOB column from it" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)
      expect(response.body).to include("preset=participants")

      get admin_event_exports_path(event_slug: event.slug, preset: "participants")
      expect(response.body).to include("not authorized to export", "Date of Birth")
      expect(response.body).not_to include("participant.date_of_birth")
    end

    it "describes the Participant category without promising a phone or an address" do
      sign_in_with_role("limited")

      get admin_event_exports_path(event_slug: event.slug)

      expect(response.body).to include("Profile information")
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

    it "omits the participant's phone but serves their email" do
      payload = show_payload

      expect(payload["email"]).to eq(participant.email)
      expect(payload).not_to have_key("phone")
    end

    it "omits a guardian's email and phone, keeping their name" do
      guardian = Guardian.create!(legal_first_name: "Katherine", legal_last_name: "Johnson",
        email: "katherine-api@example.com", phone: "+15005550003")
      participant_event.guardian_participant_events.create!(guardian: guardian, relationship: "Parent")

      guardians = show_payload["guardians"]

      expect(guardians.first["name"]).to eq("Katherine Johnson")
      expect(guardians.first).not_to have_key("email")
      expect(guardians.first).not_to have_key("phone")
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
  describe "emergency contacts" do
    let!(:emergency_contact) do
      EmergencyContact.create!(participant_event: participant_event, name: "Mary Jackson",
        phone: "+15005550002", email: "mary@example.com", relationship: "Aunt", priority: 1)
    end

    it "gives the profile a first name and a phone number, and nothing else" do
      sign_in_with_role("limited")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include("Emergency Contacts", "Mary", "+15005550002")
      expect(response.body).not_to include("Mary Jackson", "mary@example.com")
    end

    it "is not offered to ops, who never had it on the profile" do
      sign_in_with_role("ops", email: "ops-ec-spec@example.com")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).not_to include("Emergency Contacts", "+15005550002")
    end
  end

  describe "guardians" do
    let(:guardian) do
      Guardian.create!(legal_first_name: "Katherine", legal_last_name: "Johnson",
        email: "katherine@example.com", phone: "+15005550003")
    end
    let!(:gpe) do
      participant_event.guardian_participant_events.create!(guardian: guardian, relationship: "Parent")
    end

    it "shows the guardian's name but not their email or phone" do
      sign_in_with_role("limited")

      get admin_event_participant_path(event.slug, participant_event)

      expect(response.body).to include("Katherine Johnson")
      expect(response.body).not_to include("katherine@example.com", "+15005550003")
    end

    it "closes the guardian edit form, which is all their contact details" do
      sign_in_with_role("limited")

      get edit_admin_event_participant_guardian_path(event.slug, participant_event, gpe)

      expect(response).to redirect_to(admin_event_participant_path(event.slug, participant_event))
      expect(flash[:alert]).to include("cannot see their contact details")
    end

    it "refuses to link a new guardian, which means typing their contact details in" do
      sign_in_with_role("limited")

      expect {
        post link_guardian_admin_event_participant_path(event.slug, participant_event),
          params: { guardian_first_name: "Dorothy", guardian_last_name: "Hoover",
                    guardian_email: "dorothy@example.com", guardian_relationship: "Parent" }
      }.not_to change(Guardian, :count)

      expect(flash[:alert]).to include("cannot see their contact details")
    end
  end

  describe "invitations" do
    # Invitations are addressed by email, and the role can see those, so this
    # surface stays open to it.
    it "still lists pending invitations" do
      event.invitations.create!(email: "invited@example.com", expires_at: 1.week.from_now)
      sign_in_with_role("limited")

      get admin_event_participants_path(event.slug, status: "pending_invitations")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("invited@example.com")
    end
  end

  describe "the support inbox" do
    # A ticket is an email or SMS thread, keyed by the sender's address or
    # number, so there is no redacted version of it to show.
    it "is closed to the role entirely" do
      user = sign_in_with_role("limited")

      expect(TicketPolicy.new(user, Ticket).index?).to be(false)
      expect(user.support_staff_event_ids).to be_empty

      get support_tickets_path

      expect(response).to redirect_to(root_path)
    end

    it "stays open to ops" do
      user = sign_in_with_role("ops", email: "ops-support-spec@example.com")

      expect(TicketPolicy.new(user, Ticket).index?).to be(true)
    end
  end

  describe "the command palette search" do
    it "finds someone by email and shows it back" do
      sign_in_with_role("limited")

      get admin_search_path(q: participant.email), headers: { "ACCEPT" => "application/json" }

      payload = JSON.parse(response.body)
      expect(payload["participants"].first["name"]).to eq("Dorothy Vaughan")
      expect(payload["participants"].first["email"]).to eq(participant.email)
    end
  end
  describe "bulk messaging" do
    # The role keeps the ability to send; what it loses is the sight of the
    # address or number each message went to.
    it "hides the number an SMS went to, keeping the channel and status" do
      user = sign_in_with_role("limited")
      message = event.messages.create!(audience: "confirmed_attendees", channels: [ "sms" ],
        subject: "Hi", body: "<p>Hello</p>", status: "completed", sent_by_user: user)
      message.message_deliveries.create!(participant_event: participant_event, channel: "sms",
        recipient_phone: "+15005550001", status: "delivered")

      get admin_event_message_path(event_slug: event.slug, id: message)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dorothy Vaughan", "Delivered")
      expect(response.body).not_to include("+15005550001")
    end

    it "still shows the address an email went to" do
      user = sign_in_with_role("limited")
      message = event.messages.create!(audience: "confirmed_attendees", channels: [ "email" ],
        subject: "Hi", body: "<p>Hello</p>", status: "completed", sent_by_user: user)
      message.message_deliveries.create!(participant_event: participant_event, channel: "email",
        recipient_email: participant.email, status: "delivered")

      get admin_event_message_path(event_slug: event.slug, id: message)

      expect(response.body).to include(participant.email)
    end
  end
end
