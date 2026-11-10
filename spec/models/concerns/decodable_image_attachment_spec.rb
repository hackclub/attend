require "rails_helper"

# Direct uploads arrive as stored blobs nobody has checked, so the decode check
# reads them back from storage: the header when that's enough, the whole file
# when it isn't (WebP).
RSpec.describe DecodableImageAttachment do
  # Noise doesn't compress, so these come out well past the header read.
  def noisy_image
    (Vips::Image.black(1200, 1200, bands: 3) + Vips::Image.gaussnoise(1200, 1200)).cast(:uchar)
  end

  def direct_upload(bytes, content_type:, filename:)
    ActiveStorage::Blob.create_before_direct_upload!(
      filename: filename, byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes), content_type: content_type
    ).tap { |blob| blob.upload_without_unfurling(StringIO.new(bytes)) }
  end

  def headshot_errors(blob)
    Participant.new(headshot: blob).tap(&:validate).errors[:headshot]
  end

  before do
    allow(ActiveStorage::Blob.service).to receive(:download_chunk).and_call_original
    allow(ActiveStorage::Blob.service).to receive(:download).and_call_original
  end

  it "accepts a large JPEG from its header alone" do
    bytes = noisy_image.jpegsave_buffer(Q: 95)
    expect(bytes.bytesize).to be > DecodableImageAttachment::BLOB_HEADER_BYTES
    blob = direct_upload(bytes, content_type: "image/jpeg", filename: "photo.jpg")

    expect(headshot_errors(blob)).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:download)
  end

  it "reads the whole file when the header alone won't open (WebP)" do
    skip "libvips here has no WebP support" unless Vips.get_suffixes.include?(".webp")

    bytes = noisy_image.webpsave_buffer(Q: 90)
    expect(bytes.bytesize).to be > DecodableImageAttachment::BLOB_HEADER_BYTES
    blob = direct_upload(bytes, content_type: "image/webp", filename: "photo.webp")

    expect(headshot_errors(blob)).to be_empty
    expect(ActiveStorage::Blob.service).to have_received(:download).with(blob.key)
  end

  it "rejects a large file that isn't an image after reading it in full" do
    bytes = "\x89PNG\r\n\x1a\n".b + Random.bytes(DecodableImageAttachment::BLOB_HEADER_BYTES + 10)
    blob = direct_upload(bytes, content_type: "image/png", filename: "photo.png")

    expect(headshot_errors(blob)).to include(/could not be read as an image/)
  end

  it "doesn't read back a blob that's already attached elsewhere" do
    someone = create(:participant)
    someone.headshot.attach(io: Rails.root.join("spec/fixtures/files/headshot.png").open, filename: "theirs.png", content_type: "image/png")
    blob = someone.headshot.blob
    allow(ActiveStorage::Blob.service).to receive(:download_chunk).and_call_original

    expect(headshot_errors(blob)).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:download_chunk)
  end

  it "treats a direct upload that never reached storage as unreadable" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "photo.png", byte_size: 1_000, checksum: "1B2M2Y8AsgTpgAmY7PhCfg==", content_type: "image/png"
    )
    blob.update!(identified: true)

    expect(headshot_errors(blob)).to include(/could not be read as an image/)
  end
end
