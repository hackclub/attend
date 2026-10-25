require "rails_helper"

RSpec.describe Event, "waiver dates warning" do
  include ActiveSupport::Testing::TimeHelpers

  # 20:00 UTC on a day a few weeks out; still that day in New York.
  let(:day) { 3.weeks.from_now.utc.beginning_of_day + 20.hours }
  let(:event) do
    create(:event,
      timezone: "Eastern Time (US & Canada)",
      starts_at: day,
      ends_at: day + 2.days - 4.hours)
  end

  def issue_waiver(consent_type: :waiver)
    create(:consent, participant_event: create(:participant_event, event: event),
      consent_type: consent_type, status: :sent, docuseal_envelope_id: "sub_#{SecureRandom.hex(4)}")
  end

  it "flags the event when the dates move after a waiver went out" do
    issue_waiver

    freeze_time do
      event.update!(starts_at: day + 7.days, ends_at: day + 9.days - 4.hours)
      expect(event.reload.waiver_dates_stale_since).to eq(Time.current)
    end
  end

  it "counts freedom waivers too" do
    issue_waiver(consent_type: :freedom_waiver)

    event.update!(ends_at: day + 3.days - 4.hours)
    expect(event.reload).to be_waiver_dates_stale
  end

  it "still saves the new dates" do
    issue_waiver

    expect(event.update(starts_at: day + 7.days, ends_at: day + 9.days - 4.hours)).to be(true)
    expect(event.reload.starts_at).to eq(day + 7.days)
  end

  it "ignores date changes when no waiver has been sent" do
    create(:consent, participant_event: create(:participant_event, event: event), status: :pending)

    event.update!(starts_at: day + 7.days, ends_at: day + 9.days - 4.hours)
    expect(event.reload).not_to be_waiver_dates_stale
  end

  it "ignores time changes that keep the same local days" do
    issue_waiver

    event.update!(starts_at: day + 2.hours)
    expect(event.reload).not_to be_waiver_dates_stale
  end

  it "flags a timezone change that shifts the local days" do
    issue_waiver

    # 20:00 UTC is already the next day in Tokyo.
    event.update!(timezone: "Tokyo")
    expect(event.reload).to be_waiver_dates_stale
  end

  it "keeps the original timestamp across further date changes" do
    issue_waiver
    event.update!(ends_at: day + 3.days - 4.hours)
    first_flagged = event.reload.waiver_dates_stale_since

    travel 1.day do
      event.update!(ends_at: day + 4.days - 4.hours)
    end
    expect(event.reload.waiver_dates_stale_since).to eq(first_flagged)
  end

  it "doesn't flag dates being set for the first time" do
    undated = create(:event, starts_at: nil, ends_at: nil)
    create(:consent, participant_event: create(:participant_event, event: undated),
      status: :sent, docuseal_envelope_id: "sub_123")

    undated.update!(starts_at: day, ends_at: day + 2.days - 4.hours)
    expect(undated.reload).not_to be_waiver_dates_stale
  end
end
