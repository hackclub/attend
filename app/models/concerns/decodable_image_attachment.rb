# Browsers label an upload from its extension, so a renamed HEIC, a truncated
# transfer, or a file libvips refuses to open (it blocks its untrusted loaders —
# see config/initializers/vips_svg_loader.rb) all arrive looking like a
# perfectly good image/png. Vips only finds out when it opens the bytes, and by
# then we are inside the variant processor: the Active Storage representation
# request 500s, and keeps 500ing on every page that shows that photo
# (ATTEND-9H).
#
# Two guards, front and back. `validate_decodable_image` rejects the upload
# while the user is still looking at the form, and `displayable_image?` keeps
# blobs that turned out to be undecodable away from the variant processor.
#
# A direct upload (the browser PUTs the file straight to storage, see
# direct_upload_controller.js) arrives as a blob nobody has checked yet, so
# that is read back from storage and checked the same way. Only the start of
# it when that's enough: libvips reads JPEG and PNG dimensions from the
# header, but WebP wants the whole file.
module DecodableImageAttachment
  extend ActiveSupport::Concern

  # Enough for the headers of a phone JPEG (EXIF, ICC profile, thumbnail) or a
  # PNG. Anything libvips can't open from this is read in full before it's
  # rejected.
  BLOB_HEADER_BYTES = 256.kilobytes
  # Never read back more than this: every image attachment caps uploads well
  # below it, so a bigger blob fails its size check anyway.
  BLOB_DOWNLOAD_LIMIT = 25.megabytes

  # Analysis records width/height for everything Vips could open and nothing for
  # what it couldn't, so an analyzed blob with no width is one to keep away from
  # the variant processor. A blob that hasn't been analyzed yet gets the benefit
  # of the doubt; the representation controller rescue is the backstop for that
  # window (see config/initializers/active_storage_image_errors.rb).
  def self.displayable?(attachment)
    return false unless attachment&.attached?
    return false unless attachment.variable?

    blob = attachment.blob
    !blob.analyzed? || blob.metadata["width"].present?
  end

  # Skips the decode check for a blob the caller has already run through it
  # (a staged headshot, see OnboardingController#stage_headshot), so attaching
  # it doesn't read it back from storage a second time.
  def trust_decoded_image(blob)
    (@trusted_decoded_image_blob_ids ||= Set.new) << blob.id
  end

  private

  # Validates the pending attachment for `name` — a no-op when nothing new was
  # attached, so re-saving a record with an old (possibly bad) blob still works.
  def validate_decodable_image(name)
    change = attachment_changes[name.to_s]
    return unless change.respond_to?(:attachable)
    # SVGs are rasterized before save and report their own error if librsvg
    # can't read them — see RasterizesSvgLogo.
    return if change.blob.content_type == "image/svg+xml"
    # A signed blob id resolves to its blob; check that rather than the string.
    attachable = change.attachable.is_a?(String) ? change.blob : change.attachable
    return if decodable_image?(attachable)

    errors.add(name, "could not be read as an image — please re-save it as a JPEG, PNG, or WebP and upload it again")
  end

  def displayable_image?(attachment)
    DecodableImageAttachment.displayable?(attachment)
  end

  def decodable_image?(attachable)
    kind, source = decodable_image_source(attachable)
    return true if kind.nil? # Nothing we can read here — leave it to analysis.

    return stored_blob_decodable?(source) if kind == :blob

    image_width_positive?(kind, source)
  rescue Vips::Error => e
    Rails.logger.info("#{self.class.name}: rejected undecodable image upload: #{e.message}")
    false
  end

  def image_width_positive?(kind, source)
    image = if kind == :path
      Vips::Image.new_from_file(source, access: :sequential)
    else
      Vips::Image.new_from_buffer(source, "", access: :sequential)
    end
    image.width.positive?
  end

  # Header first; the whole file only when the header alone didn't open.
  def stored_blob_decodable?(blob)
    return false unless blob.byte_size.positive?

    header = blob.service.download_chunk(blob.key, 0...[ BLOB_HEADER_BYTES, blob.byte_size ].min)
    begin
      return true if image_width_positive?(:buffer, header)
    rescue Vips::Error
      raise if blob.byte_size <= BLOB_HEADER_BYTES
      return false if blob.byte_size > BLOB_DOWNLOAD_LIMIT
    end

    image_width_positive?(:buffer, blob.download)
  rescue ActiveStorage::FileNotFoundError
    # Created for a direct upload that never finished.
    false
  end

  # A path when the upload is already on disk (the common case — Rack spools
  # uploaded files to a tempfile), otherwise the bytes. Anything read here is
  # rewound: Active Storage reads the same io again when it uploads the blob.
  def decodable_image_source(attachable)
    case attachable
    when Hash
      read_image_bytes(attachable[:io])
    when ActiveStorage::Blob
      # A blob attached elsewhere (a merge moving a headshot between
      # participants, say) was validated when it was first attached, and one
      # the caller vouches for was checked before it got here. Not worth a
      # download. An unattached one is a direct upload nobody has looked at.
      return nil if @trusted_decoded_image_blob_ids&.include?(attachable.id)
      return nil if attachable.attachments.exists?

      [ :blob, attachable ]
    else
      if attachable.respond_to?(:tempfile)
        [ :path, attachable.tempfile.path ]
      elsif attachable.respond_to?(:path)
        [ :path, attachable.path ]
      else
        read_image_bytes(attachable)
      end
    end
  end

  def read_image_bytes(io)
    return nil unless io.respond_to?(:read)

    io.rewind if io.respond_to?(:rewind)
    bytes = io.read
    io.rewind if io.respond_to?(:rewind)
    [ :buffer, bytes ]
  end
end
