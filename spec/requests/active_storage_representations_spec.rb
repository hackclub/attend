require "rails_helper"

# Blobs whose bytes libvips can't decode exist in production (uploaded before
# the models started validating decodability, or from a format whose loader is
# blocked). Asking for a variant of one used to be an unhandled 500, repeated
# for every <img> on every page that showed it — ATTEND-9H.
RSpec.describe "Active Storage representations", type: :request do
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("this is not an image"),
      filename: "headshot.png",
      content_type: "image/png"
    )
  end

  it "returns 422 instead of raising when the blob can't be decoded" do
    path = Rails.application.routes.url_helpers.rails_representation_path(
      blob.variant(resize_to_fill: [ 56, 56 ]), only_path: true
    )

    get path

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "still serves a variant of a real image" do
    real = ActiveStorage::Blob.create_and_upload!(
      io: File.open(file_fixture("headshot.png")),
      filename: "headshot.png",
      content_type: "image/png"
    )
    path = Rails.application.routes.url_helpers.rails_representation_path(
      real.variant(resize_to_fill: [ 56, 56 ]), only_path: true
    )

    get path
    follow_redirect!

    expect(response).to have_http_status(:ok)
  end
end
