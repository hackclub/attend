require "rails_helper"

# Rails' direct upload endpoint hands out signed URLs to PUT into the bucket.
# DirectUploadGuard keeps that to photos picked by someone signed in.
RSpec.describe "Active Storage direct uploads", type: :request do
  include Devise::Test::IntegrationHelpers

  def start_upload(content_type: "image/png", byte_size: 1_234)
    post rails_direct_uploads_path,
         params: { blob: { filename: "photo.png", byte_size: byte_size, checksum: "1B2M2Y8AsgTpgAmY7PhCfg==", content_type: content_type } },
         as: :json
  end

  it "turns away someone who isn't signed in" do
    expect { start_upload }.not_to change(ActiveStorage::Blob, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  context "when signed in" do
    before { sign_in create(:user) }

    it "creates the blob and a signed upload URL for a photo" do
      expect { start_upload }.to change(ActiveStorage::Blob, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("signed_id" => be_present, "direct_upload" => include("url" => be_present))
    end

    it "refuses anything that isn't a photo" do
      expect { start_upload(content_type: "text/html") }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a file bigger than any photo field takes" do
      expect { start_upload(byte_size: DirectUploadGuard::MAX_BYTES + 1) }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
