require "rails_helper"

RSpec.describe "PWA files", type: :request do
  it "serves the service worker as JavaScript whatever the Accept header says", :raise_exceptions do
    get "/service-worker", headers: { "Accept" => "text/html" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/javascript")
  end

  it "serves the manifest as JSON whatever the Accept header says", :raise_exceptions do
    get "/manifest", headers: { "Accept" => "text/html" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
  end

  it "serves the manifest at the layouts' link and at the old .json path" do
    get Rails.application.routes.url_helpers.pwa_manifest_path(format: :json)
    expect(response).to have_http_status(:ok)

    get "/manifest.json"
    expect(response).to have_http_status(:ok)
  end

  it "doesn't route other extensions" do
    get "/service-worker.html"

    expect(response).to have_http_status(:not_found)
  end
end
