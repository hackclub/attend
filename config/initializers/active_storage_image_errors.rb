# A blob whose bytes libvips can't decode (a renamed HEIC, a truncated upload,
# a format whose loader the CVE-2026-66066 patch blocks) raises out of the
# variant processor inside Active Storage's own controller, so every request
# for that representation is an unhandled 500 — one per <img> on the page, for
# as long as the record exists (ATTEND-9H).
#
# Models keep known-bad blobs away from the variant processor (see
# DecodableImageAttachment); this covers the rest: blobs not yet analyzed, and
# any call site that forgets to ask. A broken image beats a 500.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.rescue_from(Vips::Error) do |error|
    Rails.logger.warn("Active Storage: could not process representation: #{error.message}")
    head :unprocessable_entity
  end
end
