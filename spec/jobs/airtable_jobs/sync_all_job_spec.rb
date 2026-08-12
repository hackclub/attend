require "rails_helper"

RSpec.describe AirtableJobs::SyncAllJob do
  def configured_event(**attrs)
    create(
      :event,
      airtable_sync_source_id: "sncTest",
      airtable_sync_table_id: "tblTest",
      config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" },
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
    broken = configured_event
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
end
