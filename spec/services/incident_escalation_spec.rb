require "rails_helper"

RSpec.describe IncidentEscalation do
  include ActiveJob::TestHelper

  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now) }
  let(:organizer) do
    create(:user, name: "Organizer Example", email: "organizer-esc@example.com").tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "event_admin")
    end
  end
  let(:incident) do
    create(:incident, event: event, reported_by: organizer, category: "medical", severity: "high",
      summary: "Allergic reaction at lunch", details: "Participant used an epipen.", actions_taken: "First aider on scene.",
      location: "Dining hall")
  end

  def escalation(**opts)
    described_class.new(incident: incident, user: organizer, reporter_phone: "+14155550199", **opts)
  end

  it "files a linked report to HQ built from the incident" do
    report = escalation(priority: "elevated").call

    expect(report).to be_persisted
    expect(incident.reload.hq_report).to eq(report)
    expect(report).to have_attributes(
      event: event, user: organizer, reporter_name: "Organizer Example", reporter_email: "organizer-esc@example.com",
      reporter_phone: "+14155550199", reporter_role: "event_point_of_contact", incident_type: "medical_emergency",
      priority: "elevated", summary: "Allergic reaction at lunch"
    )
    expect(report.details).to include("Participant used an epipen.", "Location: Dining hall", "Actions taken so far:\nFirst aider on scene.")
  end

  it "sends the same notifications a public report does" do
    expect { escalation(priority: "emergency").call }
      .to have_enqueued_job(SendIncidentReportToSlackJob)
      .and have_enqueued_job(SendIncidentReportConfirmationSmsJob)
      .and have_enqueued_job(InitiateEmergencyIncidentCallsJob)
      .and have_enqueued_mail(IncidentReportMailer, :new_report)
  end

  it "does not ring phones for a standard escalation" do
    expect { escalation.call }.not_to have_enqueued_job(InitiateEmergencyIncidentCallsJob)
  end

  it "is a no-op the second time" do
    first = escalation.call
    expect { expect(escalation.call).to eq(first) }.not_to change(IncidentReport, :count)
  end

  it "reports HQ-side errors without saving when the callback number is missing" do
    e = described_class.new(incident: incident, user: organizer)
    expect(e.valid?).to be(false)
    expect(e.errors[:reporter_phone]).to be_present
    expect { e.call }.not_to change(IncidentReport, :count)
  end

  it "flags global admins as HQ staff" do
    organizer.update!(global_role: "global_admin")
    expect(escalation.call.reporter_role).to eq("hq_employee")
  end
end
