require "rails_helper"

RSpec.describe ParticipantStatusPresenter do
  let(:event) { create(:event, starts_at: 1.day.ago, ends_at: 1.day.from_now, timezone: "UTC") }
  let(:registration) { create(:participant_event, event: event) }
  let(:staff) { create(:user) }

  def scan(name, kind, at)
    point = event.scan_contexts.find_by(name: name) || event.scan_contexts.create!(name: name, kind: kind)
    registration.scans.create!(scan_context: point, user: staff, scanned_at: at)
  end

  def status(now: Time.current)
    described_class.new(registration.reload, now: now)
  end

  it "shows the registration status until a scan places them" do
    scan("Lunch", "tracking_only", 2.hours.ago)

    expect(status.label).to eq("Awaiting participant")
    expect(status.scanned_at_label).to be_nil
  end

  it "shows where the latest placing scan puts them, with its time" do
    now = Time.current.utc.change(hour: 15, min: 0)
    scan(event.scan_contexts.first.name, "venue", now - 3.hours)
    scan("Free time", "outing", now - 1.hour)
    scan("Lunch", "tracking_only", now - 10.minutes)

    expect(status(now: now)).to have_attributes(label: "Out", tone: :wait, scanned_at_label: "14:00")
    expect(status(now: now + 1.day).scanned_at_label).to eq((now - 1.hour).strftime("%a 14:00"))
    expect(status(now: now).explanation).to include("Free time")
  end

  it "falls back to the registration status if the point stops placing people mid-request" do
    scan("Free time", "outing", 1.hour.ago)
    loaded = registration.reload.tap(&:latest_placing_scan)
    loaded.latest_placing_scan.scan_context.kind = "tracking_only"

    expect(described_class.new(loaded)).to have_attributes(label: "Awaiting participant", scanned_at_label: nil)
  end

  it "says whether they attended once the event has ended" do
    expect(status(now: 2.days.from_now).label).to eq("No-show")

    scan(event.scan_contexts.first.name, "venue", 3.hours.ago)
    expect(status(now: 2.days.from_now).label).to eq("Attended")
  end

  it "says Not coming for a withdrawn registration, whatever their scans" do
    scan(event.scan_contexts.first.name, "venue", 3.hours.ago)
    registration.update!(status: :withdrawn)

    expect(status.label).to eq("Not coming")
  end
end
