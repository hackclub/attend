require "rails_helper"

RSpec.describe "Passkit passes", type: :request do
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

  describe "downloading a pass" do
    let(:payload) { Passkit::PayloadGenerator.encrypted(Passkit::EventTicket, participant_event) }

    it "sends the pass and leaves nothing in tmp/passkit" do
      2.times do
        get "/passkit/api/v1/passes/#{payload}"
        expect_pkpass_response
      end

      expect(Dir.children(tmp_folder)).to be_empty
    end
  end

  describe "fetching a pass from Wallet" do
    let(:pass) { Passkit::Pass.create!(klass: "Passkit::EventTicket", generator: participant_event) }
    let(:path) { "/passkit/api/v1/passes/pass.com.hackclub.attend/#{pass.serial_number}" }
    let(:headers) { { "Authorization" => "ApplePass #{pass.authentication_token}" } }

    it "sends the pass and leaves nothing in tmp/passkit" do
      2.times do
        get path, headers: headers
        expect_pkpass_response
      end

      expect(Dir.children(tmp_folder)).to be_empty
    end

    it "leaves nothing in tmp/passkit when the pass has not changed" do
      # The gem builds the pass before it checks If-Modified-Since.
      get path, headers: headers.merge("If-Modified-Since" => pass.last_update.httpdate)

      expect(response).to have_http_status(:not_modified)
      expect(Dir.children(tmp_folder)).to be_empty
    end
  end
end
