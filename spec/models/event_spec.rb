require "rails_helper"

RSpec.describe Event, type: :model do
  describe "#airtable_sync_stale?" do
    def configured_event(**attrs)
      build(
        :event,
        airtable_sync_source_id: "sncTest",
        airtable_sync_table_id: "tblTest",
        config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" },
        **attrs
      )
    end

    it "is false for a sync that ran within the last window" do
      expect(configured_event(airtable_synced_at: 2.minutes.ago)).not_to be_airtable_sync_stale
    end

    it "is true once the last successful sync falls behind" do
      expect(configured_event(airtable_synced_at: 3.hours.ago)).to be_airtable_sync_stale
    end

    it "is true for a configured event that has never synced" do
      expect(configured_event(airtable_synced_at: nil)).to be_airtable_sync_stale
    end

    it "is false when the sync is not configured" do
      expect(build(:event, airtable_synced_at: nil)).not_to be_airtable_sync_stale
    end

    it "is false while the sync is paused, which reports itself" do
      event = configured_event(airtable_synced_at: 3.hours.ago, airtable_sync_paused_at: 1.hour.ago)

      expect(event).not_to be_airtable_sync_stale
    end
  end

  describe ".with_airtable_sync_active" do
    def configured_event(**attrs)
      create(
        :event,
        airtable_sync_source_id: "sncTest",
        airtable_sync_table_id: "tblTest",
        config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" },
        **attrs
      )
    end

    def event_with_raw_airtable_values(source:, table:, key:, base:)
      create(:event).tap do |event|
        event.update_columns(
          airtable_sync_source_id: source,
          airtable_sync_table_id: table,
          config: event.config.merge("airtable_api_key" => key, "airtable_base_id" => base)
        )
      end
    end

    it "includes a fully configured, unpaused event" do
      event = configured_event

      expect(described_class.with_airtable_sync_active).to include(event)
    end

    it "excludes an event with nothing configured" do
      event = create(:event)

      expect(described_class.with_airtable_sync_active).not_to include(event)
    end

    # `where.not(col: [nil, ""])` reads as if it handles this, but `normalizes`
    # rewrites the "" to nil and the predicate degrades to `IS NOT NULL`.
    it "excludes an event whose settings are stored as empty strings" do
      event = event_with_raw_airtable_values(source: "", table: "", key: "", base: "")

      expect(described_class.with_airtable_sync_active).not_to include(event)
    end

    it "excludes an event whose settings are stored as whitespace" do
      event = event_with_raw_airtable_values(source: " ", table: " ", key: " ", base: " ")

      expect(described_class.with_airtable_sync_active).not_to include(event)
    end

    it "excludes an event missing only one setting" do
      event = configured_event
      event.update_columns(airtable_sync_table_id: "")

      expect(described_class.with_airtable_sync_active).not_to include(event)
    end

    it "excludes a paused event but still counts it as configured" do
      event = configured_event(airtable_sync_paused_at: Time.current)

      expect(described_class.with_airtable_sync_configured).to include(event)
      expect(described_class.with_airtable_sync_active).not_to include(event)
    end

    it "matches the record-level #airtable_sync_configured? for every event" do
      configured_event
      create(:event)
      event_with_raw_airtable_values(source: "", table: "", key: "", base: "")
      event_with_raw_airtable_values(source: "sncTest", table: "tblTest", key: "", base: "app-test")

      expected = described_class.all.select(&:airtable_sync_configured?).map(&:id)

      expect(described_class.with_airtable_sync_configured.pluck(:id)).to match_array(expected)
    end
  end

  describe "airtable sync pausing" do
    let(:event) do
      create(
        :event,
        airtable_sync_source_id: "sncTest",
        airtable_sync_table_id: "tblTest",
        config: { "airtable_api_key" => "key-test", "airtable_base_id" => "app-test" }
      )
    end

    it "records the pause and the error that caused it" do
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      event.reload
      expect(event).to be_airtable_sync_paused
      expect(event.airtable_sync_error).to eq("HTTP 403: INVALID_PERMISSIONS")
      expect(event.airtable_sync_error_at).to be_present
    end

    it "clears the pause and the stale error on resume" do
      event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS")

      event.resume_airtable_sync!

      event.reload
      expect(event).not_to be_airtable_sync_paused
      expect(event.airtable_sync_error).to be_nil
      expect(event.airtable_sync_error_at).to be_nil
    end
  end

  describe "#airtable_config_last_saved_by" do
    let(:event) { create(:event) }

    it "is the recorded config owner" do
      owner = create(:user)
      event.update!(airtable_config_updated_by: owner)

      expect(event.airtable_config_last_saved_by).to eq(owner)
    end

    it "falls back to the most recent integrations audit log" do
      old_saver = create(:user)
      recent_saver = create(:user)
      AuditLog.log!(action: :update_integrations, record: event, event: event, actor: old_saver)
      AuditLog.log!(action: :update_integrations, record: event, event: event, actor: recent_saver)

      expect(event.airtable_config_last_saved_by).to eq(recent_saver)
    end

    it "ignores audit logs for other actions" do
      actor = create(:user)
      AuditLog.log!(action: :record_update, record: event, event: event, actor: actor)

      expect(event.airtable_config_last_saved_by).to be_nil
    end

    it "is nil when nobody is known" do
      expect(event.airtable_config_last_saved_by).to be_nil
    end
  end

  describe "airtable config normalization" do
    it "strips whitespace from copy-pasted sync ids and credentials" do
      event = build(
        :event,
        airtable_sync_source_id: " sncTest\n",
        airtable_sync_table_id: "tblTest ",
        airtable_api_key: " key-test\n",
        airtable_base_id: "appTest "
      )

      expect(event.airtable_sync_source_id).to eq("sncTest")
      expect(event.airtable_sync_table_id).to eq("tblTest")
      expect(event.airtable_api_key).to eq("key-test")
      expect(event.airtable_base_id).to eq("appTest")
    end

    it "normalizes blank values to nil" do
      event = build(:event, airtable_sync_source_id: "  ", airtable_api_key: "  ")

      expect(event.airtable_sync_source_id).to be_nil
      expect(event.airtable_api_key).to be_nil
    end
  end

  describe "banner validation" do
    let(:event) { create(:event) }

    def attach_banner(content_type:, io: StringIO.new("fake image data"))
      event.banner.attach(io: io, filename: "banner", content_type: content_type)
    end

    it "accepts a PNG banner" do
      attach_banner(content_type: "image/png")
      expect(event).to be_valid
    end

    it "accepts a JPEG banner" do
      attach_banner(content_type: "image/jpeg")
      expect(event).to be_valid
    end

    it "rejects non-PNG/JPEG banners" do
      attach_banner(content_type: "image/gif")
      expect(event).not_to be_valid
      expect(event.errors[:banner]).to include("must be a PNG or JPEG image")
    end

    it "rejects banners over 5MB" do
      attach_banner(content_type: "image/png", io: StringIO.new("x" * (5.megabytes + 1)))
      expect(event).not_to be_valid
      expect(event.errors[:banner]).to include("must be smaller than 5MB")
    end
  end
end
