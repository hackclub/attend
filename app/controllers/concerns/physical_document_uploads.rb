# Shared upload handling for physically signed custom documents — the
# participant (or guardian) uploads photos/scans of the signed paper form.
module PhysicalDocumentUploads
  extend ActiveSupport::Concern

  PHYSICAL_UPLOAD_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/heic image/heif application/pdf].freeze
  PHYSICAL_UPLOAD_MAX_BYTES = 25.megabytes
  # Documents created before we stored template_page_count have no page count
  # on file — fall back to a generous fixed cap.
  PHYSICAL_UPLOAD_FALLBACK_MAX_FILES = 10

  private

  # Attaches the uploaded files to the consent. Returns an error message
  # string when the upload is invalid, nil on success.
  def attach_physical_uploads(consent, uploads)
    files = Array(uploads).reject(&:blank?)
    return "Please choose at least one photo (or PDF scan) of the signed document." if files.empty?

    if (error = physical_upload_limit_error(consent, files))
      return error
    end

    checked = files.map do |file|
      return "Each file must be less than 25MB." if !file.respond_to?(:size) || file.size > PHYSICAL_UPLOAD_MAX_BYTES

      # Sniff the real type from the bytes — the declared content type is
      # client-controlled and can claim anything.
      content_type = sniffed_upload_content_type(file)
      unless content_type.in?(PHYSICAL_UPLOAD_CONTENT_TYPES)
        return "Uploads must be photos (JPEG, PNG, WebP, HEIC) or a PDF scan."
      end

      if content_type == "application/pdf" && !valid_pdf_upload?(file)
        return "That PDF appears to be corrupt — please re-scan and try again."
      end

      { io: file.tempfile, filename: file.original_filename, content_type: content_type, identify: false }
    end

    consent.physical_uploads.attach(checked)
    nil
  end

  # A photo per page is all a signed form can need; more usually means the
  # wrong document (or the same page over and over).
  def physical_upload_limit_error(consent, files)
    page_count = consent.custom_document&.template_page_count
    max_files = page_count || PHYSICAL_UPLOAD_FALLBACK_MAX_FILES
    return nil if consent.physical_uploads.count + files.size <= max_files

    if page_count
      "You can upload at most #{max_files} #{"file".pluralize(max_files)} for this #{page_count}-page document. Remove an upload first if you need to replace one."
    else
      "You can upload at most #{max_files} files for this document. Remove an upload first if you need to replace one."
    end
  end

  # Magic bytes only — no name/declared_type fallback, because Marcel falls
  # back to those exact client-controlled claims when it doesn't recognise
  # the bytes. Every allowed type has magic bytes, so real files still sniff.
  def sniffed_upload_content_type(file)
    io = file.tempfile
    io.rewind
    Marcel::MimeType.for(io).tap { io.rewind }
  end

  def valid_pdf_upload?(file)
    io = file.tempfile
    io.rewind
    PDF::Reader.new(io).page_count.positive?
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, ArgumentError
    false
  ensure
    io.rewind
  end

  # Purges one upload (scoped to the consent's own attachments, so an id from
  # someone else's consent can't be removed) and, when it was the last one on
  # a not-yet-signed consent, winds the consent back to pending.
  def remove_physical_upload_attachment(consent, upload_id)
    attachment = consent.physical_uploads.attachments.find(upload_id)
    attachment.purge_later

    consent.reload
    consent.reset_physical_upload_state! unless consent.physical_uploaded?
  end
end
