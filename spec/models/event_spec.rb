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
