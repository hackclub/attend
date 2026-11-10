require "rails_helper"

RSpec.describe GoogleWallet::EventTicket do
  # Banners are validated as real images, so dummy bytes won't attach.
  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  let(:participant_event) { create(:participant_event) }
  let(:event) { participant_event.event }
  let(:ticket) { described_class.new(participant_event) }

  describe "event times" do
    before do
      event.update!(
        timezone: "Pacific Time (US & Canada)",
        starts_at: Time.utc(2026, 7, 15, 1, 0), # 6pm PDT on Jul 14
        ends_at: Time.utc(2026, 7, 18, 3, 0)    # 8pm PDT on Jul 17
      )
    end

    it "expresses class start/end times in the event's timezone" do
      attrs = ticket.send(:class_attributes)
      expect(attrs[:start_date_time]).to eq("2026-07-14T18:00")
      expect(attrs[:end_date_time]).to eq("2026-07-17T20:00")
    end

    it "expresses the object validity window in the event's timezone" do
      attrs = ticket.send(:object_attributes)
      expect(attrs[:valid_time_start]).to eq("2026-07-14T18:00")
      expect(attrs[:valid_time_end]).to eq("2026-07-17T23:59")
    end
  end

  describe "#hero_image_url" do
    it "falls back to the default banner when the event has none" do
      expect(ticket.send(:hero_image_url)).to eq(described_class::HERO_IMAGE_URL)
    end

    it "uses a public proxy URL for the event banner when attached" do
      event.banner.attach(
        io: StringIO.new(ONE_PIXEL_PNG),
        filename: "banner.png",
        content_type: "image/png"
      )

      url = ticket.send(:hero_image_url)
      expect(url).to start_with("https://attend.hackclub.com/rails/active_storage/blobs/proxy/")
      expect(url).to end_with("/banner.png")
    end

    it "falls back to the series banner when the event has none" do
      series = create(:event_series)
      series.banner.attach(
        io: StringIO.new(ONE_PIXEL_PNG),
        filename: "series-banner.png",
        content_type: "image/png"
      )
      series.save!
      event.update!(event_series: series)

      url = ticket.send(:hero_image_url)
      expect(url).to start_with("https://attend.hackclub.com/rails/active_storage/blobs/proxy/")
      expect(url).to end_with("/series-banner.png")
    end
  end

  describe "#push_class_if_needed" do
    before do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    end

    def ticket_for(pe) = described_class.new(pe)

    it "pushes the event's class once, not again for the next attendee" do
      other = create(:participant_event, event: event)
      first, second = ticket_for(participant_event), ticket_for(other)
      [ first, second ].each { |t| allow(t).to receive(:push_class_with_logging).and_return(true) }

      first.send(:push_class_if_needed)
      second.send(:push_class_if_needed)

      expect(first).to have_received(:push_class_with_logging).once
      expect(second).not_to have_received(:push_class_with_logging)
    end

    it "pushes again once the event changes what the class shows" do
      allow_any_instance_of(described_class).to receive(:push_class_with_logging).and_return(true)
      ticket_for(participant_event).send(:push_class_if_needed)

      event.update!(name: "Renamed Hackathon")
      renamed = ticket_for(participant_event.reload)
      allow(renamed).to receive(:push_class_with_logging).and_return(true)
      renamed.send(:push_class_if_needed)

      expect(renamed).to have_received(:push_class_with_logging).once
    end

    it "retries a push that failed" do
      failing = ticket_for(participant_event)
      allow(failing).to receive(:push_class_with_logging).and_return(false)
      failing.send(:push_class_if_needed)

      retry_ticket = ticket_for(participant_event)
      allow(retry_ticket).to receive(:push_class_with_logging).and_return(true)
      retry_ticket.send(:push_class_if_needed)

      expect(retry_ticket).to have_received(:push_class_with_logging).once
    end
  end
end
