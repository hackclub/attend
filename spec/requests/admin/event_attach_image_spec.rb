require "rails_helper"

RSpec.describe "Admin::Events#attach_image", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { User.create!(email: "admin-attach@example.com", name: "Admin", global_role: "global_admin") }
  let(:event) { create(:event) }

  before { sign_in admin }

  def png_upload
    Rack::Test::UploadedFile.new(
      StringIO.new(Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQAY3Y2wAAAAAElFTkSuQmCC"
      )),
      "image/png",
      original_filename: "hero.png"
    )
  end

  it "attaches the banner immediately and returns preview html" do
    expect {
      patch attach_image_admin_event_path(event), params: { field: "banner", file: png_upload }
    }.to change { event.reload.banner.attached? }.from(false).to(true)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["success"]).to be(true)
    expect(body["preview_html"]).to include("banner_preview")
  end

  it "attaches the logo immediately" do
    patch attach_image_admin_event_path(event), params: { field: "logo", file: png_upload }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["success"]).to be(true)
    expect(event.reload.logo.attached?).to be(true)
  end

  it "rejects an unknown field" do
    patch attach_image_admin_event_path(event), params: { field: "avatar", file: png_upload }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["success"]).to be(false)
  end

  it "rejects a request without a file" do
    patch attach_image_admin_event_path(event), params: { field: "banner" }

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "returns a validation error for a disallowed content type" do
    svg = Rack::Test::UploadedFile.new(
      StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'></svg>"),
      "image/svg+xml",
      original_filename: "banner.svg"
    )

    patch attach_image_admin_event_path(event), params: { field: "banner", file: svg }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)["error"]).to include("PNG or JPEG")
    expect(event.reload.banner.attached?).to be(false)
  end
end
