require "rails_helper"

RSpec.describe "Passkit pass updates", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:participant_event) { create(:participant_event) }
  let(:pass) do
    Passkit::Pass.create!(
      klass: "Passkit::EventTicket",
      generator: participant_event,
      serial_number: SecureRandom.uuid,
      authentication_token: SecureRandom.hex(16)
    )
  end
  let(:pkpass) { PasskitGeneratorExtensions::Pkpass.new(filename: "pass.pkpass", data: "") }
  let(:generator) { instance_double(Passkit::Generator, generate_and_sign: pkpass) }

  before { allow(Passkit::Generator).to receive(:new).and_return(generator) }

  def fetch(since: nil, token: pass.authentication_token)
    headers = { "Authorization" => "ApplePass #{token}" }
    headers["If-Modified-Since"] = since.httpdate if since
    get "/passkit/api/v1/passes/pass.com.hackclub.attend/#{pass.serial_number}", headers: headers
  end

  it "answers 304 without building the pass when it hasn't changed" do
    fetch(since: pass.last_update)

    expect(response).to have_http_status(:not_modified)
    expect(response.headers["last-modified"]).to eq(pass.last_update.httpdate)
    expect(Passkit::Generator).not_to have_received(:new)
  end

  it "builds the pass when it changed since the device's copy" do
    fetch(since: pass.last_update - 1.minute)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.apple.pkpass")
  end

  it "builds the pass when the device has no copy to compare" do
    fetch

    expect(response).to have_http_status(:ok)
  end

  it "serves the pass again once an update touches it" do
    device_copy = pass.last_update

    # WalletPassUpdateService touches the pass, not the participant event,
    # when the event or participant changes
    travel 1.minute do
      pass.touch
      fetch(since: device_copy)
    end

    expect(response).to have_http_status(:ok)
  end

  it "still rejects a bad token that sends If-Modified-Since" do
    fetch(since: pass.last_update, token: "wrong")

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers 410 for a pass whose participant event is gone" do
    pass.update_columns(generator_id: nil, generator_type: nil)
    allow(generator).to receive(:generate_and_sign).and_raise(ActiveRecord::RecordNotFound)

    fetch(since: pass.last_update)

    expect(response).to have_http_status(:gone)
  end
end
