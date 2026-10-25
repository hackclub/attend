require "rails_helper"

# The console's participant and travel calendar pages follow Cloudscape's
# timestamp pattern (cloudscape.design/patterns/general/timestamps):
# relative times for events, wrapped in <time> with an ISO datetime and the
# absolute time as a hover title; absolute times with full month names, a
# 24-hour clock and the UTC offset where the exact moment matters.
RSpec.describe "Admin console participant timestamps and validation", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:abbreviated_month) { /\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b/ }
  let(:abbreviated_day) { /\b(Mon|Tue|Tues|Wed|Thu|Thur|Fri|Sat|Sun)\b/ }
  let(:twelve_hour) { /\b\d{1,2}(:\d{2})?\s?(AM|PM|am|pm)\b/ }

  let(:event) do
    create(:event, name: "Placeholder Timestamp Jam", timezone: "America/Los_Angeles",
      travel_enabled: true, accommodation_enabled: true,
      starts_at: Time.utc(2026, 8, 24, 16), ends_at: Time.utc(2026, 8, 26, 20))
  end
  let(:participant) do
    create(:participant, legal_first_name: "Fictional", legal_last_name: "Attendee",
      date_of_birth: Date.new(2009, 3, 14))
  end
  let!(:participant_event) { create(:participant_event, :checked_in, event: event, participant: participant, status: :complete) }
  let(:admin) do
    User.create!(email: "timestamps-admin@example.com", name: "Robin Placeholder",
      global_role: "global_admin", admin_console_beta: true)
  end

  before do
    sign_in admin

    inbound = Travel.create!(participant_event: participant_event, mode: "plane", direction: "inbound")
    create(:travel_leg, travel: inbound, departure_airport: "JFK", arrival_airport: "SFO", flight_code: "ZZ101",
      departure_time: Time.utc(2026, 8, 24, 15), arrival_time: Time.utc(2026, 8, 24, 19))
    Travel.create!(participant_event: participant_event, mode: "train", direction: "outbound",
      departure_time: Time.utc(2026, 8, 26, 18), train_departure_station: "Nowhere Central", train_arrival_station: "Elsewhere")
    Accommodation.create!(participant_event: participant_event,
      check_in_date: Date.new(2026, 8, 24), check_out_date: Date.new(2026, 8, 26))
    Note.create!(participant_event: participant_event, event: event, author: admin, note_type: "ops", body: "Placeholder note")
  end

  def page
    Nokogiri::HTML(response.body)
  end

  # Visible text only: scripts and JSON blobs can carry anything.
  def visible_text
    doc = page
    doc.css("script, style, template").each(&:remove)
    doc.at("body").text
  end

  def expect_cloudscape_timestamps
    expect(response).to have_http_status(:ok)
    text = visible_text
    expect(text).not_to match(abbreviated_month)
    expect(text).not_to match(abbreviated_day)
    expect(text).not_to match(twelve_hour)
    page.css("time").each do |time|
      expect(time["datetime"]).to be_present, "time without datetime: #{time.to_html}"
      expect { Time.iso8601(time["datetime"]) rescue Date.iso8601(time["datetime"]) }.not_to raise_error
    end
    page.css("time:not([title])").each do |time|
      # Absolute timestamps may omit the title; relative ones must carry it.
      expect(time.text).not_to match(/ago|\AIn |\ANow\z/), "relative time without title: #{time.to_html}"
    end
  end

  describe "timestamps" do
    it "follows the pattern on the participant record and every tab" do
      paths = [
        admin_event_participant_path(event, participant_event),
        travel_admin_event_participant_path(event, participant_event),
        accommodation_admin_event_participant_path(event, participant_event),
        medical_admin_event_participant_path(event, participant_event),
        safeguarding_admin_event_participant_path(event, participant_event),
        consents_admin_event_participant_path(event, participant_event),
        notes_admin_event_participant_path(event, participant_event),
        history_admin_event_participant_path(event, participant_event),
        merge_admin_event_participant_path(event, participant_event)
      ]

      paths.each do |path|
        get path
        expect_cloudscape_timestamps
      end
    end

    it "renders the date of birth, travel and stay as absolute timestamps" do
      get admin_event_participant_path(event, participant_event)

      expect_cloudscape_timestamps
      dob = page.css("time[datetime='2009-03-14']")
      expect(dob.map(&:text)).to include("March 14, 2009")
      # The flight arrives at SFO, so it shows in Pacific time with its offset.
      expect(response.body).to include("August 24, 2026, 12:00 (UTC-7:00)")
      expect(page.css("time[datetime='2026-08-24']").map(&:text)).to include("August 24, 2026")
      expect(page.css("time[datetime='2026-08-26']").map(&:text)).to include("August 26, 2026")
    end

    it "renders relative timestamps with an ISO datetime and absolute title" do
      get notes_admin_event_participant_path(event, participant_event)

      times = page.css("time[title]")
      expect(times).not_to be_empty
      times.each do |time|
        expect(time["datetime"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
        expect(time["title"]).to match(/\A[A-Z][a-z]+ \d{1,2}, \d{4}, \d{2}:\d{2} \(UTC[+-]\d+:\d{2}\)\z/)
      end
      expect(times.map(&:text)).to include("Now")
    end

    it "shows pending invitations as sent and expiring relative times" do
      create(:invitation, event: event, email: "invitee@example.com", sent_at: 2.hours.ago, expires_at: 3.days.from_now + 1.hour)

      get admin_event_participants_path(event, status: "pending_invitations")

      expect_cloudscape_timestamps
      texts = page.css("time").map(&:text)
      expect(texts).to include("2 hours ago", "In 3 days")
    end

    it "follows the pattern on the participant list and table" do
      get admin_event_participants_path(event)
      expect_cloudscape_timestamps

      get table_admin_event_participants_path(event)
      expect_cloudscape_timestamps
      expect(page.css("td[data-column='dob'] time[datetime='2009-03-14']").map(&:text)).to eq([ "March 14, 2009" ])
    end

    it "spells out day headings on the travel calendar" do
      get "/admin/events/#{event.slug}/travel"

      expect_cloudscape_timestamps
      headings = page.css("h2.cs-h2[id^='travel-day-']").map { |h2| h2.text.squish }
      expect(headings).to include("Monday, August 24, 2026 (UTC-7:00)", "Wednesday, August 26, 2026 (UTC-7:00)")
      entry_time = page.at_css("li[data-travel-calendar-filter-target~='entry'] time")
      expect(entry_time.text.strip).to eq("12:00")
      expect(entry_time["datetime"]).to eq("2026-08-24T12:00:00-07:00")
    end
  end

  # Cloudscape validation (cloudscape.design/patterns/general/errors/validation):
  # inline errors under each field, wired with aria-invalid and
  # aria-describedby, in Cloudscape wording; optional fields marked.
  describe "validation" do
    def field_error_for(control)
      ids = control["aria-describedby"].to_s.split
      page.css(".cs-field-error").find { |error| ids.include?(error["id"]) }
    end

    it "marks optional fields and leaves the edit form unvalidated on first load" do
      get edit_admin_event_participant_path(event, participant_event)

      form = page.at_css("form[data-controller~='cs-form-validation']")
      expect(form).to be_present
      expect(form).to have_attribute("novalidate")
      expect(form.css("[aria-invalid]")).to be_empty
      expect(form.css(".cs-field-error")).to be_empty
      preferred = form.at_css("label[for='participant_preferred_name']")
      expect(preferred.text).to include("Preferred name - optional")
      expect(form.at_css("label[for='participant_legal_first_name']").text.strip).to eq("Legal first name")
      expect(form.css("button[type='submit'], button:not([type])").none? { |b| b.has_attribute?("disabled") }).to be(true)
    end

    it "renders server errors inline on an invalid participant edit" do
      patch admin_event_participant_path(event, participant_event),
        params: { participant: { legal_first_name: "", email: "not-an-address" } }

      expect(response).to have_http_status(:unprocessable_content)
      first_name = page.at_css("#participant_legal_first_name")
      expect(first_name["aria-invalid"]).to eq("true")
      expect(field_error_for(first_name).text.strip).to eq("Legal first name is required.")

      email = page.at_css("#participant_email")
      expect(email["aria-invalid"]).to eq("true")
      expect(field_error_for(email).text.strip).to eq("Enter a valid email address.")

      # Every error was claimed by its field, so there's no form-level alert.
      expect(page.css(".cs-form-error")).to be_empty
    end

    it "renders a blank invite email inline with Cloudscape wording" do
      get new_invite_admin_event_participants_path(event)
      form = page.at_css("form[data-controller~='cs-form-validation']")
      expect(form).to have_attribute("novalidate")
      expect(page.at_css("label[for='invite_name']").text).to include("Name - optional")

      post send_invite_admin_event_participants_path(event), params: { invite: { email: "" } }
      expect(response).to redirect_to(new_invite_admin_event_participants_path(event))
      follow_redirect!

      email = page.at_css("#invite_email")
      expect(email["aria-invalid"]).to eq("true")
      expect(field_error_for(email).text.strip).to eq("Email address is required.")
      # Shown once, under the field, not again in the flashbar.
      expect(page.css(".cs-flash")).to be_empty
    end
  end
end
