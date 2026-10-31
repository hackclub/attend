require "rails_helper"

RSpec.describe EventLocalTimes do
  # Boston: UTC-4 in July.
  let(:event) { create(:event, timezone: "Eastern Time (US & Canada)") }
  let(:boston) { ActiveSupport::TimeZone["Eastern Time (US & Canada)"] }

  def scan_context(**attrs)
    ScanContext.new(event: event, name: "Check-in", **attrs)
  end

  describe "a new row" do
    it "reads a datetime-local value on the event's clock" do
      context = scan_context(starts_at: "2030-07-12T09:30", ends_at: "2030-07-12T17:00")
      context.validate

      expect(context.starts_at).to eq(Time.utc(2030, 7, 12, 13, 30))
      expect(context.ends_at).to eq(Time.utc(2030, 7, 12, 21, 0))
      expect(context.times_in_event_zone).to be(true)
    end

    it "keeps a value that names its own offset" do
      context = scan_context(starts_at: "2030-07-12T09:30:00Z")
      context.validate

      expect(context.starts_at).to eq(Time.utc(2030, 7, 12, 9, 30))
    end

    it "shows and prefills on the event's clock" do
      context = scan_context(starts_at: "2030-07-12T09:30")
      context.save!

      expect(context.time_display_zone).to eq(boston)
      expect(context.local_time(:starts_at).strftime("%H:%M %Z")).to eq("09:30 EDT")
      expect(context.local_time_field_value(:starts_at)).to eq("2030-07-12T09:30")
    end

    it "leaves the saved time alone when a form resubmits its own prefill" do
      context = scan_context(starts_at: "2030-07-12T09:30")
      context.save!

      context.update!(starts_at: context.local_time_field_value(:starts_at))

      expect(context.saved_changes).not_to have_key("starts_at")
    end

    it "forgets a typed value replaced before validation" do
      context = scan_context(starts_at: "2030-07-12T09:30")
      context.starts_at = nil
      context.validate

      expect(context.starts_at).to be_nil
    end
  end

  describe "a row saved before times were zoned" do
    # As older code stored them: the typed wall-clock, tagged UTC.
    let!(:context) do
      ScanContext.create!(event: event, name: "Check-in",
                          starts_at: Time.utc(2030, 7, 12, 9, 30), ends_at: Time.utc(2030, 7, 12, 17, 0)).tap do |c|
        c.update_column(:times_in_event_zone, false)
      end.reload
    end

    it "keeps showing the typed wall-clock on UTC" do
      expect(context.time_display_zone.name).to eq("UTC")
      expect(context.local_time(:starts_at).strftime("%H:%M")).to eq("09:30")
      expect(context.local_time_field_value(:starts_at)).to eq("2030-07-12T09:30")
    end

    it "is left as it was by a save that doesn't touch its times" do
      context.update!(name: "Front desk")

      expect(context.reload.times_in_event_zone).to be(false)
      expect(context.starts_at).to eq(Time.utc(2030, 7, 12, 9, 30))
    end

    it "moves every time onto the event's clock once one is resubmitted" do
      context.update!(starts_at: context.local_time_field_value(:starts_at))
      context.reload

      expect(context.times_in_event_zone).to be(true)
      expect(context.starts_at).to eq(boston.local(2030, 7, 12, 9, 30))
      expect(context.ends_at).to eq(boston.local(2030, 7, 12, 17, 0))
      expect(context.local_time_field_value(:ends_at)).to eq("2030-07-12T17:00")
    end

    it "stays on UTC when its own instant is assigned back unchanged" do
      context.update!(starts_at: context.starts_at.iso8601)

      expect(context.reload.times_in_event_zone).to be(false)
      expect(context.ends_at).to eq(Time.utc(2030, 7, 12, 17, 0))
    end

    it "keeps an assigned instant as given while moving the rest" do
      context.update!(starts_at: Time.utc(2030, 7, 12, 12, 0))
      context.reload

      expect(context.starts_at).to eq(Time.utc(2030, 7, 12, 12, 0))
      expect(context.ends_at).to eq(boston.local(2030, 7, 12, 17, 0))
    end
  end

  describe "a model without a legacy flag" do
    it "always shows on the event's clock" do
      event.update!(arrival_opens_at: "2030-07-12T09:00")

      expect(event.time_display_zone).to eq(boston)
      expect(event.local_time_field_value(:arrival_opens_at)).to eq("2030-07-12T09:00")
      expect(event.arrival_opens_at).to eq(Time.utc(2030, 7, 12, 13, 0))
    end

    it "reads times in a timezone submitted in the same assignment" do
      event.assign_attributes(arrival_opens_at: "2030-07-12T09:00", timezone: "London")
      event.validate

      expect(event.arrival_opens_at).to eq(Time.utc(2030, 7, 12, 8, 0))
    end
  end
end
