require "rails_helper"

RSpec.describe Passkit::EventTicket do
  let(:participant_event) { create(:participant_event) }
  let(:event) { participant_event.event }
  let(:pass) { described_class.new(participant_event) }
  let(:tmp_path) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp_path) }

  # Smallest valid PNG (1x1 transparent pixel)
  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  describe "#add_other_files" do
    it "does nothing when the event has no banner" do
      pass.add_other_files(tmp_path)
      expect(Dir.children(tmp_path)).to be_empty
    end

    it "writes strip images rendered from the event banner" do
      event.banner.attach(
        io: StringIO.new(ONE_PIXEL_PNG),
        filename: "banner.png",
        content_type: "image/png"
      )

      pass.add_other_files(tmp_path)

      expect(File.exist?(File.join(tmp_path, "strip.png"))).to be(true)
      expect(File.exist?(File.join(tmp_path, "strip@2x.png"))).to be(true)
      expect(File.size(File.join(tmp_path, "strip.png"))).to be > 0
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

      pass.add_other_files(tmp_path)

      expect(File.exist?(File.join(tmp_path, "strip.png"))).to be(true)
      expect(File.size(File.join(tmp_path, "strip@2x.png"))).to be > 0
    end
  end
end
