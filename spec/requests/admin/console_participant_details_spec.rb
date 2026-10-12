require "rails_helper"

# The console's participant record follows Cloudscape's "details page with
# tabs": a title with the participant's status, global actions (Edit plus an
# Actions dropdown), a details summary that reads the same on every tab, then
# at most seven link tabs starting with "Details", exactly one of them current.
RSpec.describe "Admin console participant details page", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) do
    create(:event, name: "Placeholder Details Jam", travel_enabled: true,
      accommodation_enabled: true, groups_enabled: true, freedom_waivers_enabled: true)
  end
  let(:participant) do
    create(:participant,
      legal_first_name: "Fictional", legal_last_name: "Attendee",
      date_of_birth: Date.new(2009, 3, 14),
      phone: "+15005550001",
      address_line_1: "1 Imaginary Lane", city: "Nowhereville", state: "ZZ",
      postal_code: "00000", country_of_residence: "USA")
  end
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }

  def page
    Nokogiri::HTML(response.body)
  end

  def summary_html
    nodes = page.css("[data-participant-summary]")
    expect(nodes.size).to eq(1), "expected one summary container, got #{nodes.size}"
    nodes.first.to_html
  end

  def tabs
    page.css("nav.cs-tabs a.cs-tab")
  end

  # Every route that renders the participant header, and the tab each one
  # sits under.
  def tab_pages
    {
      admin_event_participant_path(event, participant_event) => "Details",
      travel_admin_event_participant_path(event, participant_event) => "Travel",
      accommodation_admin_event_participant_path(event, participant_event) => "Details",
      medical_admin_event_participant_path(event, participant_event) => "Medical",
      safeguarding_admin_event_participant_path(event, participant_event) => "Safeguarding",
      consents_admin_event_participant_path(event, participant_event) => "Consents",
      notes_admin_event_participant_path(event, participant_event) => "Notes",
      history_admin_event_participant_path(event, participant_event) => "History",
      merge_admin_event_participant_path(event, participant_event) => "Details"
    }
  end

  describe "as a global admin" do
    let(:admin) do
      User.create!(email: "details-admin@example.com", name: "Robin Placeholder",
        global_role: "global_admin", admin_console_beta: true)
    end

    before { sign_in admin }

    it "renders every tab with the same summary, at most seven tabs and one current" do
      summaries = tab_pages.map do |path, current_label|
        get path
        expect(response).to have_http_status(:ok), "GET #{path} returned #{response.status}"

        expect(tabs.size).to be <= 7, "#{tabs.size} tabs on #{path}"
        expect(tabs.first.text.strip).to eq("Details")
        current = tabs.select { |t| t["aria-current"] == "page" }
        expect(current.size).to eq(1), "expected one current tab on #{path}, got #{current.size}"
        expect(current.first.text.squish).to start_with(current_label)

        summary_html
      end

      expect(summaries.uniq.size).to eq(1), "summary container differs between tabs"
    end

    it "shows the title with a status, an Edit button and the Actions dropdown" do
      get admin_event_participant_path(event, participant_event)

      header = page.at_css(".cs-header")
      expect(header.at_css("h1").text).to include(participant.display_name)
      expect(header.at_css(".cs-status")).to be_present
      expect(header.at_css("a.cs-btn[href='#{edit_admin_event_participant_path(event, participant_event)}']")).to be_present
      expect(header.at_css("button[data-action='dropdown#toggle']").text).to include("Actions")

      menu = header.at_css("[data-participant-actions]")
      expect(menu.text).to include("Merge duplicate", "Withdraw", "Remove from event")
    end

    it "puts onboarding, age, guardians, consents and check-in in the summary" do
      get admin_event_participant_path(event, participant_event)

      summary = page.at_css("[data-participant-summary]").text.squish
      expect(summary).to include("Onboarding", "Age at event", "Guardians", "Required consents",
        "Check-in", "Groups", "Freedom waiver")
    end
  end

  describe "as a limited-role user" do
    let(:limited_user) do
      User.create!(email: "details-limited@example.com", name: "Limited Placeholder",
        admin_console_beta: true)
    end

    before do
      EventRoleAssignment.create!(user: limited_user, event: event, role: "limited")
      sign_in limited_user
    end

    it "keeps date of birth, address and phone out of the summary on every tab it can open" do
      paths = tab_pages.keys - [ merge_admin_event_participant_path(event, participant_event) ]
      opened = 0

      paths.each do |path|
        get path
        next unless response.status == 200

        opened += 1
        summary = summary_html
        expect(summary).to include("Age at event")
        expect(summary).not_to include("March 14, 2009", "2009-03-14", "Date of birth")
        expect(summary).not_to include("1 Imaginary Lane", "Nowhereville", "00000")
        expect(summary).not_to include("+15005550001", "5005550001")
        expect(tabs.size).to be <= 7
        expect(tabs.count { |t| t["aria-current"] == "page" }).to eq(1)
      end

      expect(opened).to be >= 1
    end
  end
end
