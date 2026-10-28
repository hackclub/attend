require "rails_helper"

RSpec.describe "Google Wallet initializer" do
  # Credentials stand-in for the service account key; the gem only parses it.
  let(:credentials_json) { { type: "service_account", client_email: "wallet@example.test" }.to_json }
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:credentials_path) { root.join("tmp/certs/google_wallet_credentials.json") }

  before do
    @original_configuration = GoogleWallet.configuration
    GoogleWallet.configuration = nil
    # Point Rails.root at a scratch dir so the spec never clobbers the real
    # tmp/certs file a running dev server wrote.
    allow(Rails).to receive(:root).and_return(root)
    allow(Rails.application).to receive(:credentials)
      .and_return({ google_wallet: { credentials_json: credentials_json, issuer_id: "1234567890" } })
  end

  after do
    GoogleWallet.configuration = @original_configuration
    FileUtils.remove_entry(root)
  end

  def run_initializer
    load File.expand_path("../../config/initializers/google_wallet.rb", __dir__)
  end

  it "writes the JSON credentials to tmp/certs and loads them from there" do
    run_initializer

    expect(credentials_path.read).to eq(credentials_json)
    expect(GoogleWallet.configuration.json_credentials).to eq(JSON.parse(credentials_json))
    expect(GoogleWallet.configuration.issuer_id).to eq("1234567890")
  end

  it "never leaves the credentials file empty for a process booting alongside" do
    # bin/dev boots web and css at once and both run this initializer, so one
    # can read the file while the other rewrites it. Rewriting in place
    # (truncate, then write) let that reader see an empty file and crash boot.
    run_initializer
    writer = Thread.new { 200.times { run_initializer } }
    reads = []
    reads << credentials_path.read while writer.alive?
    writer.join

    expect(reads.uniq).to eq([ credentials_json ])
  end
end
