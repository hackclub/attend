# Deletes stored files nothing ever attached. Direct uploads (see
# utils/direct_upload.js) create the blob before the form is submitted, so a
# photo picked on a form that's then abandoned is left in the bucket with no
# record pointing at it. Staged headshots and message-editor images schedule
# their own purge after a day; this sweeps up everything else.
#
# Old enough that nothing can still be about to attach it: a direct upload's
# signed id is only honoured for DirectUploadedBlobs::DIRECT_UPLOAD_MAX_AGE,
# and a staged headshot for OnboardingController::STAGED_HEADSHOT_TTL.
class PurgeUnattachedBlobsJob < ApplicationJob
  queue_as :default

  GRACE_PERIOD = 2.days
  # Keeps one run short; anything left over goes on the next one.
  BATCH_SIZE = 500

  def perform
    ActiveStorage::Blob.unattached
      .where(created_at: ...GRACE_PERIOD.ago)
      .order(:id)
      .limit(BATCH_SIZE)
      .each do |blob|
        blob.purge
      rescue => e
        # One stubborn file shouldn't stop the rest; it's retried next run.
        Rails.logger.warn("PurgeUnattachedBlobsJob: couldn't purge blob #{blob.id}: #{e.class}: #{e.message}")
      end
  end
end
