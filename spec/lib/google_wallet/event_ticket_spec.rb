require "rails_helper"

RSpec.describe GoogleWallet::EventTicket do
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
        io: StringIO.new("fake image data"),
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
        io: StringIO.new("fake image data"),
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
end
