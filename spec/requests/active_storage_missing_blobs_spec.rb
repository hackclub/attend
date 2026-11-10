require "rails_helper"

RSpec.describe "Active Storage with missing blobs", type: :request do
  def upload_blob
    ActiveStorage::Blob.create_and_upload!(
      io: File.open(file_fixture("headshot.png")),
      filename: "headshot.png",
      content_type: "image/png"
    )
  end

  # The test env already turns RecordNotFound into a 404 page, which would hide
  # whether the controller handled it or it escaped to the error tracker.
  around do |example|
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :none
    example.run
  ensure
    env_config["action_dispatch.show_exceptions"] = original
  end

  it "404s a proxy link to a blob whose row was purged" do
    blob = upload_blob
    path = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    blob.purge

    get path

    expect(response).to have_http_status(:not_found)
  end

  it "404s a proxy link to a blob whose object is gone from storage" do
    blob = upload_blob
    blob.service.delete(blob.key)

    get Rails.application.routes.url_helpers.rails_storage_proxy_path(blob, only_path: true)

    expect(response).to have_http_status(:not_found)
  end

  describe ActiveStorage::AnalyzeJob do
    it "discards analysis of a blob whose object is gone from storage" do
      blob = upload_blob
      blob.service.delete(blob.key)

      expect { described_class.perform_now(blob) }.not_to raise_error
      expect(blob.reload).not_to be_analyzed
    end

    it "discards when S3 answers the existence check with NotFound" do
      require "aws-sdk-s3"
      blob = upload_blob
      allow_any_instance_of(ActiveStorage::Blob).to receive(:analyze)
        .and_raise(Aws::S3::Errors::NotFound.new(nil, ""))

      expect { described_class.perform_now(blob) }.not_to raise_error
    end
  end
end
