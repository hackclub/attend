# Only signed-in people may start a direct upload, and only of a photo. See
# DirectUploadGuard.
Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.include(DirectUploadGuard)
end
