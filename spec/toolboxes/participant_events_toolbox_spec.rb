require "rails_helper"

RSpec.describe ParticipantEventsToolbox do
  # Tool actions need an OAuth-authenticated Toolchest dispatch, so these drive
  # the toolbox directly with current_user stubbed.
  let(:event) { create(:event) }
  let(:user) { create(:user) }
  # Every event gets a checks_in context from Event#create_default_scan_context.
  let(:check_in) { event.scan_contexts.find_by!(checks_in: true) }
  let(:dinner) { event.scan_contexts.create!(name: "Dinner", checks_in: false) }

  def serialize(pe)
    described_class.new(params: {}).send(:serialize_registration, pe)
  end

  def run_check_in(pe, actor: user)
    toolbox = described_class.new(params: { "participant_event_id" => pe.id })
    allow(toolbox).to receive(:current_user).and_return(actor)
    allow(toolbox).to receive(:authorize!).and_return(true)
    # halt throws :halt for the Toolchest dispatch to catch; calling the action
    # directly means catching it here.
    catch(:halt) { toolbox.check_in }
    toolbox
  end

  it "reports a scanner check-in as checked in" do
    pe = create(:participant_event, event: event)
    pe.scans.create!(scan_context: check_in, user: user, scanned_at: 1.hour.ago)

    expect(serialize(pe)[:checked_in]).to be(true)
  end

  it "ignores scans in contexts that do not check in" do
    pe = create(:participant_event, event: event)
    pe.scans.create!(scan_context: dinner, user: user, scanned_at: 1.hour.ago)

    expect(serialize(pe)[:checked_in]).to be(false)
  end

  it "links every registration at its admin page, keyed by participant_event id" do
    pe = create(:participant_event, event: event)

    expect(serialize(pe)[:url]).to end_with("/admin/events/#{event.slug}/participants/#{pe.id}")
  end

  it "reports a participant with no check-in at all as not checked in" do
    expect(serialize(create(:participant_event, event: event))[:checked_in]).to be(false)
  end

  describe "#check_in" do
    it "invalidates the journey cache after toolbox check-in" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)
      pe = create(:participant_event, event: event, status: :complete)
      travel = Travel.create!(participant_event: pe, direction: "inbound", mode: "bus")

      expect(TravelCalendar::JourneyCache.fetch(event).sole[:pickup_state]).to eq(:awaiting_pickup)

      run_check_in(pe)

      expect(TravelCalendar::JourneyCache.fetch(event).sole).to include(id: travel.id, pickup_state: :checked_in)
    end

    it "records a real check-in scan attributed to the acting user" do
      check_in
      pe = create(:participant_event, event: event)

      expect { run_check_in(pe) }.to change { pe.scans.count }.by(1)

      scan = pe.scans.sole
      expect(scan.scan_context).to eq(check_in)
      expect(scan.user).to eq(user)
      expect(scan.source).to eq("manual")
      expect(pe.reload.check_in_time).to be_within(5.seconds).of(Time.current)
    end

    # Validations stop an admin from removing the last check-in context, so this
    # only happens via direct DB state — update_all skips them to reproduce it.
    it "errors instead of checking in when the event has no check-in context" do
      event.scan_contexts.update_all(checks_in: false)
      pe = create(:participant_event, event: event)

      toolbox = run_check_in(pe)

      expect(toolbox.performed?).to be(true)
      expect(pe.scans.count).to eq(0)
    end

    it "mints an NFC badge token on the first check-in when NFC is enabled" do
      check_in
      event.update!(nfc_badges_enabled: true)
      pe = create(:participant_event, event: event)
      pe.update_columns(nfc_badge_token: nil)

      run_check_in(pe)

      expect(pe.reload.nfc_badge_token).to be_present
    end

    it "keeps the earliest scan as the check-in time on a repeat check-in" do
      check_in
      pe = create(:participant_event, event: event)
      earlier = pe.scans.create!(scan_context: check_in, user: user, scanned_at: 3.hours.ago)

      run_check_in(pe)

      expect(pe.reload.check_in_time).to be_within(1.second).of(earlier.scanned_at)
    end

    it "does not mark travel pickup when checking in at the venue" do
      check_in
      pe = create(:participant_event, event: event)
      travel = Travel.create!(participant_event: pe, direction: "inbound", mode: "plane")
      leg = create(:travel_leg, travel: travel, position: 0, departure_airport: "SFO", arrival_airport: "BOS")

      run_check_in(pe)

      expect(leg.reload).not_to be_travel_picked_up
      expect(pe.reload).to be_checked_in
    end
  end
end
