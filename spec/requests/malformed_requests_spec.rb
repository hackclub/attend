require "rails_helper"

# Junk requests from crawlers and scanners get a 400, never a 500.
RSpec.describe "Malformed requests", type: :request do
  it "answers a multipart body with an oversized boundary with 400" do
    post "/visas/fictional-hackathon/apply", params: "--x\r\n",
      headers: { "CONTENT_TYPE" => "multipart/form-data; boundary=#{'a' * 100}" }

    expect(response).to have_http_status(:bad_request)
  end

  it "answers invalid UTF-8 in the path with 400" do
    get "/visas/%ff/apply"

    expect(response).to have_http_status(:bad_request)
  end
end
