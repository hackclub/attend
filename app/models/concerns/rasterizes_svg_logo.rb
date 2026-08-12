# SVG logos render as broken images in <img> tags: ActiveStorage serves
# image/svg+xml blobs as binary downloads (its stored-XSS protection, since
# SVGs can carry scripts). Rather than loosening that default and having to
# sanitize SVG markup ourselves, rasterize SVG logos to PNG at attach time.
module RasterizesSvgLogo
  extend ActiveSupport::Concern

  SVG_CONTENT_TYPE = "image/svg+xml".freeze
  RASTER_WIDTH = 512

  included do
    before_save :rasterize_svg_logo
  end

  private

  # Rewrites the pending logo attachment (via the attribute writer, which
  # replaces the queued change without triggering a nested save) so the blob
  # that actually gets stored is a PNG.
  def rasterize_svg_logo
    change = attachment_changes["logo"]
    return unless change.respond_to?(:attachable)

    attachable = change.attachable
    return unless attachable_content_type(attachable) == SVG_CONTENT_TYPE

    svg = read_attachable(attachable)
    return if svg.blank?

    png = Vips::Image.thumbnail_buffer(svg, RASTER_WIDTH).write_to_buffer(".png")
    self.logo = {
      io: StringIO.new(png),
      filename: rasterized_filename(attachable),
      content_type: "image/png"
    }
  rescue Vips::Error => e
    Rails.logger.error("#{self.class.name}: failed to rasterize SVG logo: #{e.message}")
    errors.add(:logo, "could not be processed — please upload a PNG or JPEG instead")
    throw :abort
  end

  def attachable_content_type(attachable)
    case attachable
    when Hash then attachable[:content_type]
    else attachable.try(:content_type)
    end
  end

  def read_attachable(attachable)
    case attachable
    when Hash
      io = attachable[:io]
      io.rewind if io.respond_to?(:rewind)
      io.read
    when ActiveStorage::Blob
      attachable.download
    else
      if attachable.respond_to?(:tempfile)
        attachable.tempfile.rewind
        attachable.tempfile.read
      elsif attachable.respond_to?(:read)
        attachable.rewind if attachable.respond_to?(:rewind)
        attachable.read
      end
    end
  end

  def rasterized_filename(attachable)
    base = case attachable
    when Hash then File.basename(attachable[:filename].to_s, ".*")
    when ActiveStorage::Blob then attachable.filename.base
    else File.basename(attachable.try(:original_filename).to_s, ".*")
    end
    "#{base.presence || 'logo'}.png"
  end
end
