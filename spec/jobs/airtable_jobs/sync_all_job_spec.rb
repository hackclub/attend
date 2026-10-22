require "rails_helper"

RSpec.describe AirtableJobs::SyncAllJob do
  def configured_event(**attrs)
    create(
      :event,
      airtable_sync_source_id: "sncTest",
      airtable_sync_table_id: "tblTest",
      airtable_api_key: "key-test",
      config: { "airtable_base_id" => "app-test" },
      **attrs
    )
  end

  let(:not_found) { Airtable::NotFoundError.new(response: instance_double(Faraday::Response, status: 404)) }

  def stub_sync(event, raising: nil)
    service = instance_double(Airtable::SyncService)

    if raising
      allow(service).to receive(:sync_via_api).and_raise(raising)
    else
      allow(service).to receive(:sync_via_api)
    end

    allow(Airtable::SyncService).to receive(:new).with(event).and_return(service)
    service
  end

  before { allow(Sentry).to receive(:capture_exception) }

  it "syncs the remaining events when one event's sync source 404s" do
    broken = configured_event
    healthy = configured_event
    stub_sync(broken, raising: not_found)
    healthy_service = stub_sync(healthy)

    expect { described_class.perform_now }.not_to raise_error

    expect(healthy_service).to have_received(:sync_via_api).with("tblTest", "sncTest")
    expect(healthy.reload.airtable_synced_at).to be_present
  end

  it "leaves airtable_synced_at behind for the failing event" do
    broken = configured_event(airtable_synced_at: 3.days.ago)
    stub_sync(broken, raising: not_found)

    expect { described_class.perform_now }
      .not_to change { broken.reload.airtable_synced_at }
  end

  it "records the error on the event when the sync fails" do
    broken = configured_event
    stub_sync(broken, raising: not_found)

    described_class.perform_now

    broken.reload
    expect(broken.airtable_sync_error).to eq(not_found.message)
    expect(broken.airtable_sync_error_at).to be_present
    expect(broken.airtable_synced_at).to be_nil
  end

  it "clears a previous error when the sync succeeds" do
    recovered = configured_event(
      airtable_sync_error: "HTTP 404: NOT_FOUND",
      airtable_sync_error_at: 1.hour.ago
    )
    stub_sync(recovered)

    described_class.perform_now

    recovered.reload
    expect(recovered.airtable_sync_error).to be_nil
    expect(recovered.airtable_sync_error_at).to be_nil
    expect(recovered.airtable_synced_at).to be_present
  end

  it "reports the per-event failure to Sentry with the ids needed to fix it" do
    broken = configured_event(airtable_synced_at: 3.days.ago)
    stub_sync(broken, raising: not_found)

    described_class.perform_now

    expect(Sentry).to have_received(:capture_exception) do |exception, **options|
      expect(exception).to eq(not_found)
      expect(options[:tags]).to include(job: "airtable_sync_all", event_slug: broken.slug, airtable_status: 404)
      expect(options[:contexts][:airtable_sync]).to include(
        event_id: broken.id,
        table_id: "tblTest",
        sync_source_id: "sncTest",
        base_id: "app-test"
      )
      expect(options[:fingerprint]).to eq([ "airtable-sync-all", "Airtable::NotFoundError", broken.id ])
    end
  end

  it "groups Airtable server errors into one issue instead of one per event" do
    server_error = Airtable::ServerError.new(
      "HTTP 504: Gateway Time-out",
      response: instance_double(Faraday::Response, status: 504)
    )
    broken = configured_event(airtable_sync_failures: Event::AIRTABLE_SYNC_ALERT_AFTER_FAILURES - 1)
    stub_sync(broken, raising: server_error)

    described_class.perform_now

    expect(Sentry).to have_received(:capture_exception) do |_exception, **options|
      expect(options[:fingerprint]).to eq([ "airtable-sync-all", "Airtable::ServerError" ])
    end
    expect(broken.reload.airtable_sync_error).to eq(server_error.message)
  end

  it "syncs the remaining events when one event fails before any request is made" do
    broken = configured_event
    healthy = configured_event
    allow(Airtable::SyncService).to receive(:new).with(broken)
      .and_raise(ArgumentError, "Airtable API key is required")
    healthy_service = stub_sync(healthy)

    expect { described_class.perform_now }.not_to raise_error

    expect(healthy_service).to have_received(:sync_via_api).with("tblTest", "sncTest")
    broken.reload
    expect(broken.airtable_sync_error).to eq("Airtable API key is required")
    expect(broken.airtable_sync_error_at).to be_present

    expect(Sentry).to have_received(:capture_exception) do |exception, **options|
      expect(exception).to be_a(ArgumentError)
      expect(options[:tags]).to include(airtable_status: nil)
      expect(options[:fingerprint]).to eq([ "airtable-sync-all", "ArgumentError", broken.id ])
    end
  end

  it "does not report anything when every event syncs" do
    stub_sync(configured_event)

    described_class.perform_now

    expect(Sentry).not_to have_received(:capture_exception)
  end

  it "skips events without a full sync configuration" do
    create(:event, airtable_sync_source_id: "sncTest", airtable_sync_table_id: "tblTest")
    allow(Airtable::SyncService).to receive(:new)

    described_class.perform_now

    expect(Airtable::SyncService).not_to have_received(:new)
  end

  # The bug behind thousands of identical Sentry errors: saving the integrations
  # form with the Airtable fields blank leaves empty strings behind, and the old
  # `where.not(col: [nil, ""])` filter let them through because `normalizes`
  # collapsed the "" in the query to nil.
  it "skips events whose Airtable settings are stored as blank strings" do
    event = create(:event)
    event.update_columns(
      airtable_sync_source_id: "",
      airtable_sync_table_id: "",
      config: event.config.merge("airtable_api_key" => "", "airtable_base_id" => "")
    )
    allow(Airtable::SyncService).to receive(:new)

    described_class.perform_now

    expect(Airtable::SyncService).not_to have_received(:new)
    expect(Sentry).not_to have_received(:capture_exception)
  end

  it "skips events whose Airtable settings are only whitespace" do
    event = create(:event)
    event.update_columns(
      airtable_sync_source_id: "  ",
      airtable_sync_table_id: "  ",
      config: event.config.merge("airtable_api_key" => " ", "airtable_base_id" => " ")
    )
    allow(Airtable::SyncService).to receive(:new)

    described_class.perform_now

    expect(Airtable::SyncService).not_to have_received(:new)
  end

  describe "pausing on a config error" do
    it "pauses the event's sync on the first failure" do
      broken = configured_event
      stub_sync(broken, raising: not_found)

      described_class.perform_now

      expect(broken.reload.airtable_sync_paused?).to be(true)
    end

    it "keeps syncing after a rate limit and counts the failure" do
      flaky = configured_event
      service = stub_sync(flaky, raising: Airtable::RateLimitError.new)

      described_class.perform_now
      described_class.perform_now

      flaky.reload
      expect(flaky.airtable_sync_paused?).to be(false)
      expect(flaky.airtable_sync_failures).to eq(2)
      expect(service).to have_received(:sync_via_api).twice
    end

    it "does not touch a healthy event's pause state" do
      healthy = configured_event
      stub_sync(healthy)

      described_class.perform_now

      expect(healthy.reload.airtable_sync_paused?).to be(false)
    end

    it "stops attempting the event on later runs" do
      broken = configured_event
      service = stub_sync(broken, raising: not_found)

      described_class.perform_now
      described_class.perform_now
      described_class.perform_now

      expect(service).to have_received(:sync_via_api).once
      expect(Sentry).to have_received(:capture_exception).once
    end

    it "flags the pause on the Sentry report" do
      broken = configured_event
      stub_sync(broken, raising: not_found)

      described_class.perform_now

      expect(Sentry).to have_received(:capture_exception) do |_exception, **options|
        expect(options[:tags]).to include(airtable_sync_paused: true)
        expect(options[:contexts][:airtable_sync][:paused_at]).to be_present
      end
    end
  end

  describe "notifying the config owner" do
    it "emails whoever last saved the Airtable settings" do
      owner = create(:user)
      broken = configured_event(airtable_config_updated_by: owner)
      stub_sync(broken, raising: not_found)

      expect { described_class.perform_now }
        .to have_enqueued_mail(AirtableMailer, :sync_paused)
        .with(event: broken, recipient: owner, error_message: not_found.message)
    end

    it "emails only once, because the event stays paused" do
      owner = create(:user)
      broken = configured_event(airtable_config_updated_by: owner)
      stub_sync(broken, raising: not_found)

      expect do
        described_class.perform_now
        described_class.perform_now
        described_class.perform_now
      end.to have_enqueued_mail(AirtableMailer, :sync_paused).once
    end

    it "falls back to the last admin who saved the integrations form" do
      saver = create(:user)
      broken = configured_event
      AuditLog.log!(action: :update_integrations, record: broken, event: broken, actor: saver)
      stub_sync(broken, raising: not_found)

      expect { described_class.perform_now }
        .to have_enqueued_mail(AirtableMailer, :sync_paused)
        .with(hash_including(recipient: saver))
    end

    it "prefers the recorded owner over the audit trail" do
      owner = create(:user)
      older_saver = create(:user)
      broken = configured_event(airtable_config_updated_by: owner)
      AuditLog.log!(action: :update_integrations, record: broken, event: broken, actor: older_saver)
      stub_sync(broken, raising: not_found)

      expect { described_class.perform_now }
        .to have_enqueued_mail(AirtableMailer, :sync_paused)
        .with(hash_including(recipient: owner))
    end

    it "still pauses and reports when nobody is known to email" do
      broken = configured_event
      stub_sync(broken, raising: not_found)

      expect { described_class.perform_now }
        .not_to have_enqueued_mail(AirtableMailer, :sync_paused)

      expect(broken.reload.airtable_sync_paused?).to be(true)
      expect(Sentry).to have_received(:capture_exception) do |_exception, **options|
        expect(options[:contexts][:airtable_sync][:notified]).to match(/nobody/)
      end
    end

    it "keeps syncing the other events when the notification blows up" do
      owner = create(:user)
      broken = configured_event(airtable_config_updated_by: owner)
      healthy = configured_event
      stub_sync(broken, raising: not_found)
      healthy_service = stub_sync(healthy)
      allow(AirtableMailer).to receive(:sync_paused).and_raise(StandardError, "smtp is down")

      expect { described_class.perform_now }.not_to raise_error

      expect(healthy_service).to have_received(:sync_via_api)
      expect(broken.reload.airtable_sync_paused?).to be(true)
    end
  end

  describe "alerting on a lasting transient failure" do
    let(:server_error) { Airtable::ServerError.new(response: instance_double(Faraday::Response, status: 503)) }
    let(:owner) { create(:user) }
    let(:threshold) { Event::AIRTABLE_SYNC_ALERT_AFTER_FAILURES }

    it "emails the config owner and reports once the threshold is reached" do
      flaky = configured_event(airtable_config_updated_by: owner, airtable_sync_failures: threshold - 1)
      stub_sync(flaky, raising: server_error)

      expect { described_class.perform_now }
        .to have_enqueued_mail(AirtableMailer, :sync_failing)
        .with(event: flaky, recipient: owner, error_message: server_error.message, failures: threshold)

      expect(flaky.reload.airtable_sync_alerted_at).to be_present
      expect(Sentry).to have_received(:capture_exception) do |_exception, **options|
        expect(options[:tags]).to include(airtable_sync_paused: false)
        expect(options[:contexts][:airtable_sync]).to include(consecutive_failures: threshold)
      end
    end
  end

  describe "syncing a single event" do
    it "syncs only the event it is given" do
      wanted = configured_event
      other = configured_event
      wanted_service = stub_sync(wanted)
      allow(Airtable::SyncService).to receive(:new).with(other)

      described_class.perform_now(wanted.id)

      expect(wanted_service).to have_received(:sync_via_api)
      expect(Airtable::SyncService).not_to have_received(:new).with(other)
    end
  end
end
