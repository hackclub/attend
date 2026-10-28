require "rails_helper"

RSpec.describe "Api::V1::IncidentReports", type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user, name: "Sam Reporter", email: "reporter-api@example.com") }
  let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(user).token}" } }
  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now) }
  let(:json) { JSON.parse(response.body) }

  let(:report_params) do
    { reporter_name: "Sam Reporter", reporter_email: "reporter-api@example.com", reporter_phone: "+14155550150",
      reporter_role: "participant", incident_type: "event_safety", priority: "s2",
      summary: "Someone was rude", details: "At lunch." }
  end

  describe "GET options" do
    it "offers the running events and prefills the reporter" do
      event
      create(:event, starts_at: 2.years.ago, ends_at: 2.years.ago + 2.days)

      get api_v1_incident_reports_options_path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["events"]).to eq([ { "value" => event.id, "label" => event.name, "emergency_allowed" => true } ])
      expect(json["prefill"]).to include("reporter_name" => "Sam Reporter", "reporter_email" => "reporter-api@example.com")
      expect(json["roles"].map { |r| r["value"] }).to include("participant", "parent")
    end
  end

  describe "POST create" do
    it "files a report linked to the account and sends the notifications" do
      expect {
        post api_v1_incident_reports_path, params: { incident_report: report_params, event_choice: event.id }, headers: headers
      }.to change(IncidentReport, :count).by(1).and have_enqueued_job(SendIncidentReportToSlackJob)

      expect(response).to have_http_status(:created)
      expect(IncidentReport.last).to have_attributes(user: user, event: event)
    end

    it "accepts attachments as multipart" do
      file = Rack::Test::UploadedFile.new(StringIO.new("photo"), "image/jpeg", original_filename: "photo.jpg")

      post api_v1_incident_reports_path,
        params: { incident_report: report_params.merge(attachments: [ file ]), event_choice: event.id }, headers: headers

      expect(response).to have_http_status(:created)
      expect(IncidentReport.last.attachments.map { |a| a.filename.to_s }).to eq([ "photo.jpg" ])
    end

    it "forces S0 when emergency services were called" do
      post api_v1_incident_reports_path,
        params: { incident_report: report_params.merge(incident_type: "medical_emergency", emergency_services_called: "1"), event_choice: event.id },
        headers: headers

      expect(json["incident_report"]["priority"]).to eq("s0")
    end

    it "asks for an event when the id isn't one the form offers" do
      old = create(:event, starts_at: 2.years.ago, ends_at: 2.years.ago + 2.days)

      post api_v1_incident_reports_path, params: { incident_report: report_params, event_choice: old.id }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["errors"]).to include("Please choose an event")
    end
  end
end
