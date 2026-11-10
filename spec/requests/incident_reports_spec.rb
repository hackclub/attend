require "rails_helper"

RSpec.describe "Public incident form", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:event) { create(:event, name: "Example Camp", starts_at: 1.day.ago, ends_at: 1.day.from_now) }

  it "points organizers at their event's incident log" do
    organizer = create(:user, email: "organizer-public@example.com")
    EventRoleAssignment.create!(user: organizer, event: event, role: "ops")
    sign_in organizer

    get incident_report_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Organizing one of these events?", new_admin_event_incident_path(event))
  end

  it "says nothing about the log to a participant" do
    sign_in create(:user, email: "attendee-public@example.com")
    get incident_report_path
    expect(response.body).not_to include("Organizing one of these events?")
  end

  describe "support gate" do
    it "asks what they need before showing the form" do
      get incident_report_path
      html = Nokogiri::HTML(response.body)

      gate = html.at_css('[data-incident-report-target="gate"]')
      section = html.at_css('[data-incident-report-target="reportSection"]')
      expect(gate["class"]).not_to include("hidden")
      expect(gate.text).to include("Report a safety concern", "Get help with my event")
      expect(section["class"]).to include("hidden")
      expect(section.at_css("form")).to be_present
      expect(html.at_css('[data-incident-report-target="supportPanel"] a[href^="mailto:"]')).to be_present
    end

    it "skips the question when re-rendering a failed submit" do
      sign_in create(:user, email: "rerender-public@example.com")
      post incident_report_path, params: { incident_report: { summary: "" }, event_choice: event.id }
      expect(response).to have_http_status(:unprocessable_content)
      html = Nokogiri::HTML(response.body)

      expect(html.at_css('[data-incident-report-target="gate"]')["class"]).to include("hidden")
      expect(html.at_css('[data-incident-report-target="reportSection"]')["class"]).not_to include("hidden")
    end
  end

  it "labels the catch-all type as a safety concern" do
    get incident_report_path
    expect(response.body).to include("Other safety or wellbeing concern")
    expect(response.body).not_to include(">Other</option>")
  end

  it "warns about misuse next to the submit button without scaring off genuine reports" do
    get incident_report_path
    submit = Nokogiri::HTML(response.body).at_css('input[type="submit"][value="Submit report"]')
    form = submit.ancestors("form").first
    expect(form.text.squish).to include("permanent ban from all Hack Club events", "report it anyway")
  end

  it "renders for signed-out visitors with the levels and a link to the triage chart" do
    get incident_report_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("S0 · High priority", "/docs/organizers/reporting-incidents")
  end
end
