require "rails_helper"

RSpec.describe "Passkit pass files", type: :request do
  let(:participant_event) { create(:participant_event) }
  let(:tmp_folder) { Pathname.new(Dir.mktmpdir) }

  before do
    stub_const("Passkit::Generator::TMP_FOLDER", tmp_folder)
    # Real signing needs the Apple certificates, which the test env lacks.
    allow_any_instance_of(Passkit::Generator).to receive(:sign_manifest)
  end

  after { FileUtils.remove_entry(tmp_folder) }

  def expect_pkpass_response
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.apple.pkpass")
    expect(response.headers["Content-Disposition"]).to match(/attachment; filename=".+\.pkpass"/)
    entries = Zip::File.open_buffer(response.body).map(&:name)
    expect(entries).to include("pass.json", "manifest.json")
  end

  it "sends a downloaded pass and leaves nothing in tmp/passkit" do
    payload = Passkit::PayloadGenerator.encrypted(Passkit::EventTicket, participant_event)

    2.times do
      get "/passkit/api/v1/passes/#{payload}"
      expect_pkpass_response
    end

    expect(Dir.children(tmp_folder)).to be_empty
  end

  it "sends a pass Wallet fetches and leaves nothing in tmp/passkit" do
    pass = Passkit::Pass.create!(klass: "Passkit::EventTicket", generator: participant_event)

    2.times do
      get "/passkit/api/v1/passes/pass.com.hackclub.attend/#{pass.serial_number}",
        headers: { "Authorization" => "ApplePass #{pass.authentication_token}" }
      expect_pkpass_response
    end

    expect(Dir.children(tmp_folder)).to be_empty
  end
end
