# Photo fields that upload straight from the browser to storage (see
# direct_upload_controller.js) send back the signed id of the blob they made
# instead of the file. This turns that id back into a blob the request may
# attach.
#
# Only a fresh, unattached blob qualifies. Rails hands out signed blob ids in
# every storage URL it renders, so without the unattached check one person
# could attach (and later purge, by replacing it) a photo that belongs to
# someone else.
module DirectUploadedBlobs
  extend ActiveSupport::Concern

  # Longer than this and the blob is fair game for PurgeUnattachedBlobsJob.
  DIRECT_UPLOAD_MAX_AGE = 1.day

  private

  def find_direct_uploaded_blob(signed_id)
    return unless signed_id.is_a?(String) && signed_id.present?

    blob = ActiveStorage::Blob.find_signed(signed_id)
    return unless blob
    return if blob.created_at < DIRECT_UPLOAD_MAX_AGE.ago
    return if blob.attachments.exists?

    blob
  end

  # A direct upload the model refused has nothing pointing at it; don't leave
  # it in the bucket until the nightly sweep.
  def discard_direct_upload(blob)
    blob.purge_later if blob && !blob.attachments.exists?
  end
end
