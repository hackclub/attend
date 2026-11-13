require "rails_helper"

RSpec.describe "Admin search", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:participant) do
    create(:participant, legal_first_name: "Ada", legal_last_name: "Lovelace", slack_user_id: "U0TESTADA1")
  end
  let!(:participant_event) do
    create(:participant_event, event: event, participant: participant, slack_user_id: "U0TESTADA1")
  end

  # Event staff search through a join onto participant_events, which has its
  # own slack_user_id column, so an unqualified column name was ambiguous.
  it "finds a participant by Slack ID for event staff, whose search joins registrations" do
    user = User.create!(email: "search-staff@example.com", name: "Staff", admin_console_beta: false)
    EventRoleAssignment.create!(user: user, event: event, role: "ops")
    sign_in user

    get admin_search_path(q: "u0testada1"), headers: { "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["participants"].map { |p| p["id"] }).to eq([ participant_event.id ])
  end

  describe "accents" do
    let(:admin) do
      User.create!(email: "search-accents@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false)
    end

    def results_for(query, key)
      get admin_search_path(q: query), headers: { "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)[key]
    end

    before { sign_in admin }

    it "finds an accented event name from an unaccented query" do
      accented = create(:event, name: "Harbour Montréal", location_city: "Montréal")

      expect(results_for("montreal", "events").map { |e| e["id"] }).to eq([ accented.id ])
    end

    it "finds an event from an accented query against an unaccented name" do
      plain = create(:event, name: "Harbour Sao Paulo")

      expect(results_for("São Paulo", "events").map { |e| e["id"] }).to eq([ plain.id ])
    end

    it "finds an accented participant name from an unaccented query" do
      accented = create(:participant, legal_first_name: "Zoë", legal_last_name: "Éclair")
      pe = create(:participant_event, event: event, participant: accented)

      expect(results_for("zoe eclair", "participants").map { |p| p["id"] }).to include(pe.id)
    end

    it "finds an accented guardian name from an unaccented query" do
      guardian = create(:guardian, legal_first_name: "Inès", legal_last_name: "Gonçalves")
      link = create(:guardian_participant_event, guardian: guardian, participant_event: participant_event)

      expect(results_for("goncalves", "guardians").map { |g| g["id"] }).to eq([ link.id ])
    end
  end

  describe "parents and guardians" do
    let(:guardian) do
      create(:guardian, legal_first_name: "Charles", legal_last_name: "Babbage", email: "difference.engine@example.com")
    end
    let!(:link) { create(:guardian_participant_event, guardian: guardian, participant_event: participant_event) }
    let(:other_event) { create(:event) }

    def sign_in_with_role(role)
      user = User.create!(email: "search-#{role}@example.com", name: "Staff", admin_console_beta: false)
      EventRoleAssignment.create!(user: user, event: event, role: role)
      sign_in user
      user
    end

    def guardians_for(query)
      get admin_search_path(q: query), headers: { "ACCEPT" => "application/json" }
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)["guardians"]
    end

    it "finds a guardian by part of their email and links to their child's registration" do
      sign_in_with_role("ops")

      results = guardians_for("difference.eng")

      expect(results.size).to eq(1)
      expect(results.first).to include(
        "name" => "Charles Babbage",
        "email" => "difference.engine@example.com",
        "participant_name" => "Ada Lovelace",
        "url" => admin_event_participant_path(event, participant_event)
      )
    end

    it "finds a guardian by name" do
      sign_in_with_role("event_admin")

      expect(guardians_for("charles babbage").map { |g| g["id"] }).to eq([ link.id ])
    end

    it "leaves out guardians of children at events the staff member doesn't work" do
      other_pe = create(:participant_event, event: other_event)
      create(:guardian_participant_event, guardian: guardian, participant_event: other_pe)
      sign_in_with_role("ops")

      expect(guardians_for("difference.engine").map { |g| g["id"] }).to eq([ link.id ])
    end

    it "returns nothing to the limited role, which can't see guardian contact details" do
      sign_in_with_role("limited")

      expect(guardians_for("difference.engine")).to eq([])
    end

    it "lets global admins search across every event" do
      other_pe = create(:participant_event, event: other_event)
      create(:guardian_participant_event, guardian: guardian, participant_event: other_pe)
      sign_in User.create!(email: "search-global@example.com", name: "Admin", global_role: "global_admin", admin_console_beta: false)

      expect(guardians_for("difference.engine").size).to eq(2)
    end
  end
end
