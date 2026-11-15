require "rails_helper"

RSpec.describe "SMS opt-out link", type: :request do
  let(:phone) { "+447911123456" }
  let(:token) { SmsOptOut.token_for(phone) }

  it "asks before opting out, so opening the link alone changes nothing" do
    get sms_opt_out_path(token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ending <strong>3456</strong>").and include("Stop texts")
    expect(response.body).not_to include(phone)
    expect(SmsOptOut.opted_out?(phone)).to be(false)
  end

  it "opts the number out, and back in" do
    post sms_opt_out_path(token)
    follow_redirect!

    expect(SmsOptOut.find_by(phone_number: phone)).to have_attributes(source: "link")
    expect(response.body).to include("Turn texts back on")

    delete sms_opt_out_path(token)

    expect(SmsOptOut.opted_out?(phone)).to be(false)
  end

  it "refuses a tampered link" do
    post sms_opt_out_path("447911123457-#{token.split('-').last}")

    expect(response).to have_http_status(:not_found)
    expect(SmsOptOut.count).to eq(0)
  end
end
