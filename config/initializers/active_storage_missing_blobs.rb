# Blobs go missing in two ways: the row is purged while a signed URL to it is
# still cached in a page, an email or a wallet pass, or the row survives but
# its object never made it to (or was removed from) the bucket. Neither is
# fixable by retrying, so neither should page anyone.
#
# S3Service only translates NoSuchKey into ActiveStorage::FileNotFoundError;
# the HEAD request it makes before streaming raises Aws::S3::Errors::NotFound.
# That one's named as a string: aws-sdk-s3 is required lazily, by the service,
# and rescue_from resolves string names only when an error is raised.
Rails.application.config.to_prepare do
  missing_object_errors = [ ActiveStorage::FileNotFoundError, "Aws::S3::Errors::NotFound" ]

  # A link to a purged blob, or to one whose bytes are gone, is a 404, not a 500.
  ActiveStorage::BaseController.rescue_from(ActiveRecord::RecordNotFound, *missing_object_errors) do |error|
    Rails.logger.info("Active Storage: blob not found: #{error.class}")
    head :not_found
  end

  # Analysis (dimensions, etc.) of a blob whose object isn't there can never
  # succeed. The blob just stays unanalyzed.
  ActiveStorage::AnalyzeJob.discard_on(*missing_object_errors) do |job, error|
    Rails.logger.warn("Active Storage: skipped analyzing blob #{job.arguments.first&.id}: #{error.class}")
  end
end
