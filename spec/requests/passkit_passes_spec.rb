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

  # Building and signing needs Apple certificates, so only that step is
  # stubbed; pass.json is still assembled for real, which is what
  # WalletPassContent fingerprints.
  before do
    allow(Passkit::Generator).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |generator| allow(generator).to receive(:generate_and_sign).and_return(pkpass) }
    end
  end

  def fetch(since: nil, token: pass.authentication_token)
    headers = { "Authorization" => "ApplePass #{token}" }
    headers["If-Modified-Since"] = since.httpdate if since
    get "/passkit/api/v1/passes/pass.com.hackclub.attend/#{pass.serial_number}", headers: headers
  end

  def built_pass?
    response.media_type == "application/vnd.apple.pkpass"
  end

  it "answers 304 without building the pass when it hasn't changed" do
    fetch(since: pass.last_update)

    expect(response).to have_http_status(:not_modified)
    expect(response.headers["last-modified"]).to eq(pass.reload.last_update.httpdate)
  end

  it "builds the pass when it changed since the device's copy" do
    fetch(since: pass.last_update - 1.minute)

    expect(response).to have_http_status(:ok)
    expect(built_pass?).to be(true)
  end

  it "builds the pass when the device has no copy to compare" do
    fetch

    expect(response).to have_http_status(:ok)
  end

  it "keeps a pass's existing last-modified the first time it's fingerprinted" do
    device_copy = pass.last_update

    travel 1.minute do
      fetch(since: device_copy)
    end

    expect(response).to have_http_status(:not_modified)
    expect(pass.reload.content_digest).to be_present
    expect(pass.content_updated_at.to_i).to eq(device_copy.to_i)
  end

  it "answers 304 when records were saved but nothing on the pass changed" do
    fetch
    device_copy = Time.httpdate(response.headers["last-modified"])

    travel 1.minute do
      participant_event.touch
      participant_event.participant.update!(pronouns: "they/them")
      fetch(since: device_copy)
    end

    expect(response).to have_http_status(:not_modified)
  end

  it "serves the pass again once something on it changes" do
    fetch
    device_copy = Time.httpdate(response.headers["last-modified"])

    travel 1.minute do
      participant_event.event.update!(name: "Renamed Hackathon")
      fetch(since: device_copy)
    end

    expect(response).to have_http_status(:ok)
    expect(built_pass?).to be(true)
  end

  it "still rejects a bad token that sends If-Modified-Since" do
    fetch(since: pass.last_update, token: "wrong")

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers 410 for a pass whose participant event is gone" do
    pass.update_columns(generator_id: nil, generator_type: nil)

    fetch(since: pass.last_update)

    expect(response).to have_http_status(:gone)
  end
end
