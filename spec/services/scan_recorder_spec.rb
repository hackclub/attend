require "rails_helper"

RSpec.describe ScanRecorder do
  subject(:record_scan) do
    described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      scanned_at: scanned_at,
      client_scan_id: client_scan_id,
      source: "qr"
    )
  end

  let(:participant_event) { create(:participant_event) }
  let(:scan_context) { participant_event.event.scan_contexts.find_by!(checks_in: true) }
  let(:user) { create(:user) }
  let(:scanned_at) { Time.zone.parse("2026-08-24 09:41:00") }
  let(:client_scan_id) { SecureRandom.uuid }

  it "classifies the first context attempt as scanned" do
    result = record_scan

    expect(result.outcome).to eq("scanned")
    expect(result.first_scan_in_context?).to be(true)
    expect(result.deduplicated?).to be(false)
    expect(result.first_scanned_at).to eq(result.scan.scanned_at)
  end

  it "retains and classifies a later context attempt as already scanned" do
    first = record_scan
    second = described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      scanned_at: scanned_at + 1.minute,
      client_scan_id: SecureRandom.uuid,
      source: "qr"
    )

    expect(second.outcome).to eq("already_scanned")
    expect(second.first_scan_in_context?).to be(false)
    expect(second.first_scanned_at).to eq(first.scan.scanned_at)
    expect(participant_event.scans.where(scan_context: scan_context).count).to eq(2)
  end

  it "returns the original scan for a transport retry" do
    first = record_scan
    retry_result = described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      scanned_at: scanned_at + 2.minutes,
      client_scan_id: client_scan_id,
      source: "qr"
    )

    expect(retry_result.scan.id).to eq(first.scan.id)
    expect(retry_result.outcome).to eq("scanned")
    expect(retry_result.deduplicated?).to be(true)
    expect(participant_event.scans.count).to eq(1)
  end

  it "classifies attempts independently in different contexts" do
    record_scan
    exit_context = participant_event.event.scan_contexts.create!(name: "Exit", checks_in: false)

    result = described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: exit_context,
      scanned_at: scanned_at + 1.minute,
      client_scan_id: SecureRandom.uuid,
      source: "qr"
    )

    expect(result.outcome).to eq("scanned")
  end

  context "with concurrent attempts" do
    before(:context) do
      @concurrent_event = FactoryBot.create(:event, slug: "concurrent-scans-#{SecureRandom.hex(8)}")
      @concurrent_participant_event = FactoryBot.create(:participant_event, event: @concurrent_event)
      @concurrent_context = @concurrent_participant_event.event.scan_contexts.find_by!(checks_in: true)
      @concurrent_user = FactoryBot.create(:user)
    end

    after(:context) do
      @concurrent_participant_event.destroy!
      @concurrent_event.destroy!
      @concurrent_user.destroy!
    end

    it "classifies exactly one attempt as the first scan" do
      ready = Queue.new
      release = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            release.pop
            described_class.call(
              participant_event: @concurrent_participant_event,
              user: @concurrent_user,
              scan_context: @concurrent_context,
              scanned_at: Time.current,
              client_scan_id: SecureRandom.uuid,
              source: "qr"
            )
          end
        end
      end

      2.times { ready.pop }
      2.times { release << true }
      results = threads.map(&:value)

      expect(results.map(&:outcome).sort).to eq(%w[already_scanned scanned])
      expect(@concurrent_participant_event.scans.where(scan_context: @concurrent_context).count).to eq(2)
    end
  end
end
