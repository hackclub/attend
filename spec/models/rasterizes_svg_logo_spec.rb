require "rails_helper"

RSpec.describe RasterizesSvgLogo, type: :model do
  let(:svg) { '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></svg>' }

  shared_examples "rasterizes svg logos" do
    it "converts an attached SVG logo to PNG on save" do
      record.logo.attach(io: StringIO.new(svg), filename: "logo.svg", content_type: "image/svg+xml")
      record.save!
      record.reload

      expect(record.logo.content_type).to eq("image/png")
      expect(record.logo.filename.to_s).to eq("logo.png")
      expect(record.logo.variable?).to be(true)
    end

    it "leaves raster logos untouched" do
      png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
      record.logo.attach(io: StringIO.new(png), filename: "logo.png", content_type: "image/png")
      record.save!

      expect(record.reload.logo.filename.to_s).to eq("logo.png")
      expect(record.logo.content_type).to eq("image/png")
    end

    it "rejects unprocessable SVG data with a validation error" do
      record.logo.attach(io: StringIO.new("definitely not svg"), filename: "bad.svg", content_type: "image/svg+xml")

      expect(record.save).to be(false)
      expect(record.errors[:logo]).to include("could not be processed — please upload a PNG or JPEG instead")
    end
  end

  # image_processing/vips blocks every untrusted libvips loader — including SVG —
  # the moment it is required, which happens lazily the first time an
  # ActiveStorage variant is processed. config/initializers/vips_svg_loader.rb
  # forces that require at boot and re-allows the SVG loader, so rasterizing does
  # not depend on what the process happened to do earlier.
  it "can load SVG even though image_processing has blocked untrusted loaders" do
    require "image_processing/vips"

    expect { Vips::Image.thumbnail_buffer(svg, 8).write_to_buffer(".png") }.not_to raise_error
  end

  describe Event do
    let(:record) { build(:event) }

    include_examples "rasterizes svg logos"
  end

  describe EventSeries do
    let(:record) { build(:event_series) }

    include_examples "rasterizes svg logos"
  end
end
