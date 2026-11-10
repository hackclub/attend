# Rails mounts Active Storage's direct upload endpoint for everyone, and each
# call hands back a signed URL to PUT a file into the bucket. Attend only uses
# it for photos picked by a signed-in person (see utils/direct_upload.js), so
# that's all it accepts. Anything it turns away falls back to posting the file
# with the form, where the model says what's wrong with it.
#
# Mixed into ActiveStorage::DirectUploadsController by
# config/initializers/active_storage_direct_uploads.rb.
module DirectUploadGuard
  extend ActiveSupport::Concern

  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  # The photo fields cap uploads at 10MB; leave a little room so the model
  # gets to say so rather than an opaque refusal here.
  MAX_BYTES = 20.megabytes

  included do
    before_action :require_direct_upload_user
    before_action :require_direct_upload_photo
  end

  private

  def require_direct_upload_user
    head :unauthorized unless user_signed_in?
  end

  def require_direct_upload_photo
    blob = params[:blob]
    return head(:unprocessable_content) unless blob.respond_to?(:[])

    byte_size = blob[:byte_size].to_i
    return if blob[:content_type].in?(CONTENT_TYPES) && byte_size.positive? && byte_size <= MAX_BYTES

    head :unprocessable_content
  end
end
