require "rails_helper"

# A browser behind a compression proxy (Opera Mini, for one) arrives with a
# Forwarded header naming itself and an X-Forwarded-For that also lists the
# proxy. Rails used to call that IP spoofing and 500 the request.
RSpec.describe "A client-supplied Forwarded header", type: :request do
  it "is ignored, so the request is served and the client IP comes from X-Forwarded-For", :raise_exceptions do
    get "/up", headers: {
      "X-Forwarded-For" => "198.51.100.7, 203.0.113.9",
      "Forwarded" => 'for="198.51.100.7:48089"'
    }

    expect(response).to have_http_status(:ok)
    expect(request.remote_ip).to eq("203.0.113.9")
  end

  it "can't choose the host or scheme Rails sees" do
    get "/up", headers: { "Forwarded" => "host=evil.example.com;proto=https" }

    expect(request.host).to eq("www.example.com")
    expect(request.ssl?).to be(false)
  end
end
