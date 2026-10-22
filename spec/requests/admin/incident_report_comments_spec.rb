require "rails_helper"

RSpec.describe "Admin::IncidentReportComments", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:event) { create(:event) }
  let(:global_admin) { User.create!(email: "ga-irc@example.com", name: "Global Admin", global_role: "global_admin") }

  let(:incident_report) do
    IncidentReport.create!(
      event: event,
      reporter_name: "Reporter",
      reporter_email: "reporter-irc@example.com",
      reporter_phone: "+14155550150",
      reporter_role: "participant",
      incident_type: "other",
      priority: "s2",
      summary: "Summary",
      details: "Details"
    )
  end

  before { sign_in global_admin }

  it "attaches uploaded files to the comment" do
    expect {
      post admin_incident_report_comments_path(incident_report), params: {
        incident_report_comment: {
          body: "Adding evidence",
          attachments: [ fixture_file_upload(Rails.root.join("spec/fixtures/files/evidence.txt"), "text/plain") ]
        }
      }
    }.to change { incident_report.comments.count }.by(1)

    comment = incident_report.comments.last
    expect(comment.attachments).to be_attached
    expect(comment.attachments.first.filename.to_s).to eq("evidence.txt")
  end

  it "changes the status even when the report itself no longer passes validation" do
    # A legacy row whose phone predates the E.164 rule.
    incident_report.update_column(:reporter_phone, "555-0150")
    expect(incident_report.reload).not_to be_valid

    expect {
      post admin_incident_report_comments_path(incident_report), params: {
        incident_report_comment: { body: "Looked into it", new_status: "resolved" }
      }
    }.to change { incident_report.comments.count }.by(1)

    expect(response).to redirect_to(admin_incident_report_path(incident_report))
    expect(incident_report.reload.status).to eq("resolved")
  end

  it "creates a comment with no attachments when none are provided" do
    post admin_incident_report_comments_path(incident_report), params: {
      incident_report_comment: { body: "No files here" }
    }

    comment = incident_report.comments.last
    expect(comment.body).to eq("No files here")
    expect(comment.attachments).not_to be_attached
  end
end
