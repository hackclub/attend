require "rails_helper"

RSpec.describe ScanTimestamp do
  let(:now) { Time.zone.parse("2026-08-24 09:41:00") }

  def resolve(scanned:, sent: nil)
    described_class.resolve(client_scanned_at: scanned, client_sent_at: sent, now: now)
  end

  it "uses the server's time when the device sends none" do
    expect(resolve(scanned: nil)).to have_attributes(scanned_at: now, client_scanned_at: nil, adjusted?: false)
    expect(resolve(scanned: "")).to have_attributes(scanned_at: now, client_scanned_at: nil)
  end

  it "ignores a time it can't parse" do
    expect(resolve(scanned: "not a time", sent: "nor this")).to have_attributes(scanned_at: now, client_scanned_at: nil, adjusted?: false)
  end

  it "subtracts how long the device held the scan from the server's time" do
    result = resolve(scanned: (now - 45.minutes).iso8601, sent: now.iso8601)

    expect(result).to have_attributes(scanned_at: now - 45.minutes, client_scanned_at: now - 45.minutes, adjusted?: false)
  end

  it "measures the wait on the device's own clock, however wrong it is" do
    device_now = now - 6.hours
    result = resolve(scanned: (device_now - 45.minutes).iso8601, sent: device_now.iso8601)

    expect(result).to have_attributes(scanned_at: now - 45.minutes, client_scanned_at: device_now - 45.minutes, adjusted?: false)
  end

  it "compares with the server clock when there is no send time" do
    expect(resolve(scanned: (now - 5.minutes).iso8601).scanned_at).to eq(now - 5.minutes)
  end

  it "honours a wait right up to the limit" do
    result = resolve(scanned: (now - described_class::MAX_AGE).iso8601, sent: now.iso8601)

    expect(result).to have_attributes(scanned_at: now - described_class::MAX_AGE, adjusted?: false)
  end

  it "falls back to the server's time past the limit, keeping the claim" do
    claimed = now - described_class::MAX_AGE - 1.second
    result = resolve(scanned: claimed.iso8601, sent: now.iso8601)

    expect(result).to have_attributes(scanned_at: now, client_scanned_at: claimed, adjusted?: true)
  end

  it "treats a scan slightly newer than its send time as just scanned" do
    result = resolve(scanned: (now + described_class::MAX_FUTURE_SKEW).iso8601, sent: now.iso8601)

    expect(result).to have_attributes(scanned_at: now, adjusted?: false)
  end

  it "falls back to the server's time for a scan well after its send time" do
    claimed = now + described_class::MAX_FUTURE_SKEW + 1.second
    result = resolve(scanned: claimed.iso8601, sent: now.iso8601)

    expect(result).to have_attributes(scanned_at: now, client_scanned_at: claimed, adjusted?: true)
  end

  it "never resolves to a time in the future" do
    [ now + 1.minute, now + 1.year, now - 1.year ].each do |claimed|
      expect(resolve(scanned: claimed.iso8601).scanned_at).to be <= now
    end
  end
end
