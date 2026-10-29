require "rails_helper"

# Timestamps in the Cloudscape console follow Cloudscape's timestamp pattern:
# relative times in a <time> whose title holds the absolute time, absolute
# times with full month names, a 24-hour clock and the UTC offset, and no
# abbreviated months anywhere.
RSpec.describe "Admin console timestamps", type: :request do
  include Devise::Test::IntegrationHelpers

  ABBREVIATED_MONTH = /\b(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\b(?!\w)/
  ABSOLUTE = /\A[A-Z][a-z]+ \d{1,2}, \d{4}(, \d{2}:\d{2} \(UTC[+-]\d{1,2}:\d{2}\))?\z/

  let(:admin) do
    User.create!(email: "time-admin@example.com", name: "Robin Placeholder",
      global_role: "global_admin", admin_console_beta: true)
  end
  let(:event) { create(:event, name: "Timestamp Test Jam", starts_at: 3.days.from_now, ends_at: 5.days.from_now) }
  let(:participant) { create(:participant, legal_first_name: "Fictional", legal_last_name: "Attendee") }
  let!(:participant_event) { create(:participant_event, event: event, participant: participant) }

  before { sign_in admin }

  def times
    Nokogiri::HTML(response.body).css("main time, [role=main] time, body time")
  end

  def expect_compliant(path)
    get path
    expect(response).to have_http_status(:ok), "GET #{path} returned #{response.status}"
    body = Nokogiri::HTML(response.body).at_css("body")
    body.css("script, style, template").each(&:remove)
    expect(body.text).not_to match(ABBREVIATED_MONTH), "abbreviated month on #{path}"
    expect(body.text).not_to match(/\b\d{1,2}:\d{2}\s?(AM|PM)\b/), "12-hour clock on #{path}"
    found = times
    found.each do |node|
      expect(node["datetime"]).to be_present, "time without datetime on #{path}"
      label = node["title"] || node.text.strip
      expect(label).to match(ABSOLUTE), "#{label.inspect} on #{path}"
    end
    found
  end

  it "renders event pages with compliant timestamps" do
    incident = Incident.create!(event: event, reported_by: admin, category: :other, severity: :s3,
      summary: "A made-up incident", occurred_at: 2.hours.ago)
    event.update!(registration_open_at: 10.days.ago, registration_close_at: 1.day.from_now)
    context = ScanContext.create!(event: event, name: "Front desk", starts_at: 1.day.from_now, ends_at: 2.days.from_now)
    Scan.create!(participant_event: participant_event, scan_context: context, user: admin, scanned_at: 10.minutes.ago)
    message = Message.create!(event: event, sent_by_user: admin, audience: "all_attendees", channels: [ "email" ],
      subject: "Made-up update", body: "Hello", status: "completed", sent_at: 3.hours.ago)
    MessageDelivery.create!(message: message, participant_event: participant_event, channel: "email",
      status: "delivered", delivered_at: 2.hours.ago, read_at: 1.hour.ago)
    scheduled = Message.create!(event: event, sent_by_user: admin, audience: "all_attendees", channels: [ "email" ],
      subject: "Later", body: "Soon", status: "scheduled", scheduled_at: 2.days.from_now)
    EventApiToken.generate_for(event, user: admin, name: "made-up-token")

    expect(expect_compliant(admin_event_dashboard_path(event.slug))).not_to be_empty
    expect(expect_compliant(admin_event_messages_path(event))).not_to be_empty
    expect(expect_compliant(admin_event_message_path(event, message))).not_to be_empty
    expect(expect_compliant(admin_event_message_path(event, scheduled))).not_to be_empty
    expect(expect_compliant(admin_event_scans_path(event))).not_to be_empty
    expect(expect_compliant(scanner_admin_event_scans_path(event))).not_to be_empty
    expect_compliant(admin_event_scan_contexts_path(event))
    expect(response.body).to include("(UTC+0:00)")
    expect(expect_compliant(admin_event_incidents_path(event))).not_to be_empty
    expect(expect_compliant(admin_event_incident_path(event, incident))).not_to be_empty
    expect_compliant(admin_event_setup_review_path(event.slug))
    expect(response.body).to match(/[A-Z][a-z]+ \d{1,2}( – [A-Z][a-z]+)? ?–? ?\d{1,2}, \d{4}/)
    expect(expect_compliant(admin_event_integrations_path(event.slug))).not_to be_empty
    expect_compliant(admin_event_staff_index_path(event))
  end

  it "renders global pages with compliant timestamps" do
    other = User.create!(email: "time-other@example.com", name: "Sam Sample", last_sign_in_at: 2.days.ago)
    EventRoleAssignment.create!(user: other, event: event, role: "event_admin")
    GlobalApiToken.generate_for(admin, name: "made-up-global")
    ban = create(:ban, email: "nobody@example.com", expires_at: 30.days.from_now)
    log = create(:email_log, :opened)
    create(:email_log_event, email_log: log, occurred_at: 1.hour.ago)
    audit = AuditLog.create!(actor: admin, event: event, record_type: "Event", record_id: event.id, action: "record_update")

    expect(expect_compliant(admin_users_path)).not_to be_empty
    expect(expect_compliant(admin_user_path(other))).not_to be_empty
    expect(expect_compliant(admin_global_api_tokens_path)).not_to be_empty
    expect(expect_compliant(admin_bans_path)).not_to be_empty
    expect(expect_compliant(admin_ban_path(ban))).not_to be_empty
    expect(expect_compliant(admin_email_logs_path)).not_to be_empty
    expect(expect_compliant(admin_email_log_path(log))).not_to be_empty
    expect(expect_compliant(admin_audit_logs_path)).not_to be_empty
    expect(expect_compliant(admin_audit_log_path(audit))).not_to be_empty
  end

  it "renders series, blast, report and preview pages with compliant timestamps" do
    series = create(:event_series, name: "Placeholder Series")
    event.update!(event_series: series)
    create(:series_role_assignment, event_series: series, user: admin, role: "owner")
    SeriesApiToken.generate_for(series, user: admin, name: "made-up-series-token")
    blast = create(:slack_blast, event: event, sent_by_user: admin, status: "completed")
    report = IncidentReport.create!(event: event, reporter_name: "Pat Placeholder", reporter_email: "pat@example.com",
      reporter_phone: "+14155550150", reporter_role: "participant", incident_type: "other",
      priority: "s2", summary: "Made-up summary", details: "Made-up details")
    scheduled = Message.create!(event: event, sent_by_user: admin, audience: "all_attendees", channels: [ "email" ],
      subject: "Later", body: "Soon", status: "draft", scheduled_at: 2.days.from_now)

    expect(expect_compliant(admin_series_path(series.slug))).not_to be_empty
    expect(expect_compliant(admin_series_members_path(series.slug))).not_to be_empty
    expect(expect_compliant(admin_series_api_tokens_path(series.slug))).not_to be_empty
    expect(expect_compliant(admin_event_slack_blasts_path(event))).not_to be_empty
    expect(expect_compliant(admin_event_slack_blast_path(event, blast))).not_to be_empty
    expect(expect_compliant(admin_incident_reports_path)).not_to be_empty
    expect(expect_compliant(admin_incident_report_path(report))).not_to be_empty
    expect(expect_compliant(preview_admin_event_message_path(event, scheduled))).not_to be_empty
    expect_compliant(admin_settings_path)
    expect(expect_compliant(admin_series_index_path)).to be_empty

    # The side nav heads the event's own pages with its dates, months in full.
    get admin_event_slack_blasts_path(event)
    expect(Nokogiri::HTML(response.body).at_css(".cs-sidenav-header").text).to include(event.starts_at.strftime("%B"))
  end

  it "shows relative times with the absolute time on hover" do
    Incident.create!(event: event, reported_by: admin, category: :other, severity: :s3, summary: "Made up")

    get admin_event_dashboard_path(event.slug)
    node = times.find { |t| t.text.strip == "Now" }

    expect(node).to be_present
    expect(node["title"]).to match(/\A[A-Z][a-z]+ \d{1,2}, \d{4}, \d{2}:\d{2} \(UTC\+0:00\)\z/)
  end
end
