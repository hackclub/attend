class Message
  # An image staff dropped, pasted or picked in the message editor. It's checked
  # and stored before any message is saved (a new one may not exist yet), so it
  # isn't tied to one: saving a body that shows it attaches it (see
  # Message#attach_images_in_body), and one that never is goes after a day.
  class ImageUpload
    UNSAVED_TTL = 1.day
    # Plenty for a phone photo (48MP sensors are common) while keeping a
    # crafted "40000x40000" PNG out of the resizer.
    MAX_PIXELS = 60_000_000

    def initialize(file, event:)
      @file = file
      @event = event
    end

    # Why the file can't go in a message body, or nil when it can.
    def error
      return "Please choose an image." unless @file.respond_to?(:tempfile)
      # What the bytes are, not what the browser called them: a HEIC renamed to
      # .jpg arrives labelled image/jpeg, and Active Storage would store (and
      # email) it as the HEIC it really is.
      return "Choose a JPEG, PNG, GIF, or WebP image." unless content_type.in?(IMAGE_CONTENT_TYPES)
      return "Images must be less than 10MB." if @file.size > MAX_IMAGE_SIZE
      return "That image could not be read. Please re-save it as a JPEG, PNG, or WebP and upload it again." unless dimensions
      return "That image is too large. Please use one under 60 megapixels." if dimensions.inject(:*) > MAX_PIXELS

      nil
    end

    # Stores the file and returns its blob. Call only when #error is nil.
    def store!
      width, height = dimensions
      @file.tempfile.rewind
      blob = ActiveStorage::Blob.create_and_upload!(
        io: @file.tempfile,
        filename: @file.original_filename,
        content_type: content_type,
        # Width and height now rather than from the analyzer, which only runs
        # once the image is attached: a message sent straight after saving
        # would otherwise go out without the width Outlook needs.
        metadata: { IMAGE_EVENT_KEY => @event.id, "width" => width, "height" => height }
      )
      # Blob#purge leaves one that's been attached by then alone.
      ActiveStorage::PurgeJob.set(wait: UNSAVED_TTL).perform_later(blob)
      # Resized in the background rather than in this request, and before the
      # first recipient opens it, so a big send doesn't have everyone's first
      # open racing to make it.
      ActiveStorage::TransformJob.perform_later(blob, IMAGE_VARIANT) if Message.image_variant(blob)
      blob
    end

    private

    def content_type
      @content_type ||= Marcel::MimeType.for(
        Pathname.new(@file.tempfile.path), name: @file.original_filename.to_s, declared_type: @file.content_type
      )
    end

    # [width, height] as shown (an EXIF-rotated photo swaps them, the way Active
    # Storage's analyzer reports it), or nil when libvips can't open the file.
    # Reads only the header, so a huge image is caught before it's decoded.
    def dimensions
      return @dimensions if defined?(@dimensions)

      @dimensions = begin
        image = Vips::Image.new_from_file(@file.tempfile.path, access: :sequential)
        size = [ image.width, image.height ]
        rotated = image.get_typeof("orientation").positive? && image.get("orientation").to_i.between?(5, 8)
        size.all?(&:positive?) ? (rotated ? size.reverse : size) : nil
      rescue Vips::Error => e
        Rails.logger.info("Message::ImageUpload: rejected undecodable image upload: #{e.message}")
        nil
      end
    end
  end
end
