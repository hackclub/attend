require "rails_helper"

RSpec.describe ScanRecorder do
  include ActiveSupport::Testing::TimeHelpers

  subject(:record_scan) do
    described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      client_scanned_at: scanned_at,
      client_scan_id: client_scan_id,
      source: "qr"
    )
  end

  let(:participant_event) { create(:participant_event) }
  let(:scan_context) { participant_event.event.scan_contexts.find_by!(checks_in: true) }
  let(:user) { create(:user) }
  let(:scanned_at) { 10.minutes.ago.change(usec: 0) }
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
      client_scanned_at: scanned_at + 1.minute,
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
      client_scanned_at: scanned_at + 2.minutes,
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
      client_scanned_at: scanned_at + 1.minute,
      client_scan_id: SecureRandom.uuid,
      source: "qr"
    )

    expect(result.outcome).to eq("scanned")
  end

  context "with concurrent attempts" do
    # The racing threads each need their own connection, so the fixtures have to
    # be visible outside the example's transaction: `before(:context)` commits
    # them. Nothing rolls that back, so `after(:context)` has to delete every
    # row (and every PaperTrail version) the setup created, or the leftovers
    # survive into later runs and break other specs' table-wide counts.
    before(:context) do
      @concurrent_event = FactoryBot.create(:event, slug: "concurrent-scans-#{SecureRandom.hex(8)}")
      @concurrent_participant_event = FactoryBot.create(:participant_event, event: @concurrent_event)
      @concurrent_participant = @concurrent_participant_event.participant
      @concurrent_context = @concurrent_participant_event.event.scan_contexts.find_by!(checks_in: true)
      @concurrent_user = FactoryBot.create(:user)
    end

    after(:context) do
      records = [ @concurrent_participant_event, @concurrent_event, @concurrent_participant, @concurrent_user ]
      record_ids = records.compact.map(&:id)
      records.each(&:destroy!)
      PaperTrail::Version.where(item_id: record_ids).delete_all
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

  it "keeps the device's own time for the scan beside the recorded one" do
    freeze_time do
      claimed = 3.days.from_now
      result = described_class.call(
        participant_event: participant_event,
        user: user,
        scan_context: scan_context,
        client_scanned_at: claimed - 3.minutes,
        client_sent_at: claimed,
        client_scan_id: client_scan_id,
        source: "qr"
      )

      expect(result.scan.reload.scanned_at).to be_within(1.second).of(3.minutes.ago)
      expect(result.scan.client_scanned_at).to be_within(1.second).of(claimed - 3.minutes)
      expect(result.time_adjusted?).to be(false)
    end
  end

  it "records the server's time for a device time out of bounds" do
    freeze_time do
      result = described_class.call(
        participant_event: participant_event,
        user: user,
        scan_context: scan_context,
        client_scanned_at: 1.year.ago,
        client_scan_id: client_scan_id,
        source: "qr"
      )

      expect(result.scan.scanned_at).to be_within(1.second).of(Time.current)
      expect(result.time_adjusted?).to be(true)
    end
  end

  # A scan held on a device while offline reaches the server after a later
  # scan of the same person from another device. It is still the first, as it
  # is for the participant's check-in time.
  it "decides the first scan by when it happened, not when it arrived" do
    later = record_scan
    earlier = described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      client_scanned_at: scanned_at - 5.minutes,
      client_scan_id: SecureRandom.uuid,
      source: "qr"
    )

    expect(later.first_scan_in_context?).to be(true)
    expect(earlier.first_scan_in_context?).to be(true)
    expect(earlier.first_scanned_at).to eq(earlier.scan.scanned_at)
    expect(participant_event.reload.check_in_time).to eq(earlier.scan.reload.scanned_at)

    retry_of_later = described_class.call(
      participant_event: participant_event,
      user: user,
      scan_context: scan_context,
      client_scanned_at: scanned_at,
      client_scan_id: client_scan_id,
      source: "qr"
    )
    expect(retry_of_later).to have_attributes(outcome: "already_scanned", first_scanned_at: earlier.scan.scanned_at)
  end

  it "refuses an id already used for another person or scan point" do
    record_scan
    other = create(:participant_event, event: participant_event.event)

    expect {
      described_class.call(
        participant_event: other,
        user: user,
        scan_context: scan_context,
        client_scan_id: client_scan_id,
        source: "qr"
      )
    }.to raise_error(ScanRecorder::ClientScanIdConflict)
    expect(other.scans).to be_empty
  end

  it "only treats a clash on the scan id as a retry" do
    invalid = Scan.new.tap { |scan| scan.errors.add(:scanned_at, :blank) }
    allow(participant_event.scans).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))
    allow(participant_event).to receive(:scans).and_return(participant_event.scans)

    expect { record_scan }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
