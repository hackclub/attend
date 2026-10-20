# Fake OAuth app credentials for GitHub and itch.io account linking specs.
module AccountLinkingCredentials
  def stub_account_linking_credentials(github: true, itch: true)
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:github, :client_id).and_return(github ? "gh-client" : nil)
    allow(Rails.application.credentials).to receive(:dig).with(:github, :client_secret).and_return(github ? "gh-secret" : nil)
    allow(Rails.application.credentials).to receive(:dig).with(:itch, :client_id).and_return(itch ? "itch-client" : nil)
  end
end

RSpec.configure do |config|
  config.include AccountLinkingCredentials
end
