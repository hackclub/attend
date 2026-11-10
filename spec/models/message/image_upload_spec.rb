require "rails_helper"

RSpec.describe Message::ImageUpload do
  let(:event) { create(:event) }

  def uploaded(path, content_type, filename: File.basename(path))
    ActionDispatch::Http::UploadedFile.new(tempfile: File.open(path), filename: filename, type: content_type)
  end

  def file_with(contents, extension)
    Tempfile.new([ "upload", extension ], binmode: true).tap do |file|
      file.write(contents)
      file.flush
    end
  end

  def upload(file)
    described_class.new(file, event: event)
  end

  describe "#error" do
    it "accepts an image it can read" do
      expect(upload(uploaded(file_fixture("headshot.png"), "image/png")).error).to be_nil
    end

    it "rejects other kinds of file" do
      expect(upload(uploaded(file_fixture("evidence.txt"), "text/plain")).error)
        .to eq("Choose a JPEG, PNG, GIF, or WebP image.")
    end

    it "goes by what the file is, not what the browser called it" do
      svg = file_with(%(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"></svg>), ".png")
      tiff = file_with(Vips::Image.black(4, 4).write_to_buffer(".tif"), ".jpg")

      expect(upload(uploaded(svg.path, "image/png", filename: "map.png")).error)
        .to eq("Choose a JPEG, PNG, GIF, or WebP image.")
      expect(upload(uploaded(tiff.path, "image/jpeg", filename: "map.jpg")).error)
        .to eq("Choose a JPEG, PNG, GIF, or WebP image.")
    end

    it "rejects a file that claims to be an image but can't be read" do
      broken = file_with(File.binread(file_fixture("headshot.png")).byteslice(0, 40), ".png")

      expect(upload(uploaded(broken.path, "image/png")).error).to start_with("That image could not be read.")
    end

    it "rejects an image with too many pixels before resizing it" do
      stub_const("#{described_class}::MAX_PIXELS", 500)
      png = file_with(Vips::Image.black(30, 20).write_to_buffer(".png"), ".png")

      expect(upload(uploaded(png.path, "image/png")).error)
        .to eq("That image is too large. Please use one under 60 megapixels.")
    end

    it "rejects a missing file" do
      expect(upload(nil).error).to eq("Please choose an image.")
      expect(upload("not a file").error).to eq("Please choose an image.")
    end
  end

  describe "#store!" do
    it "stores the image with its real type and size, tagged with the event" do
      png = file_with(Vips::Image.black(30, 20).write_to_buffer(".png"), ".jpg")
      blob = upload(uploaded(png.path, "image/jpeg", filename: "map.jpg")).store!

      expect(blob.content_type).to eq("image/png")
      expect(blob.metadata).to include(Message::IMAGE_EVENT_KEY => event.id, "width" => 30, "height" => 20)
    end

    it "resizes it in the background and cleans it up later if no message uses it" do
      file = uploaded(file_fixture("headshot.png"), "image/png")

      expect { upload(file).store! }
        .to have_enqueued_job(ActiveStorage::TransformJob)
        .and have_enqueued_job(ActiveStorage::PurgeJob)
    end
  end
end
