require "rails_helper"

RSpec.describe Privacy::Token do
  before do
    reset_privacy_jwks_cache
    stub_privacy_jwks
  end

  it "returns the claims of a valid token, with emails lowercased" do
    claims = described_class.verify!(privacy_token(privacy_claims(emails: [ "Someone@Example.com" ], slack_id: "U0FAKE")))

    expect(claims.action).to eq("delete")
    expect(claims.dry_run).to be(true)
    expect(claims.subject.emails).to eq([ "someone@example.com" ])
    expect(claims.subject.slack_id).to eq("U0FAKE")
  end

  {
    "missing_token" => -> { nil },
    "alg_not_allowed" => -> { privacy_token(privacy_claims, header: { alg: "HS256" }) },
    "invalid_typ" => -> { privacy_token(privacy_claims, header: { typ: "at+jwt" }) },
    "unknown_kid" => -> { privacy_token(privacy_claims, header: { kid: "someone-else" }) },
    "bad_signature" => -> { privacy_token(privacy_claims, key: OpenSSL::PKey::EC.generate("prime256v1")) },
    "invalid_iss" => -> { privacy_token(privacy_claims(iss: "someone-else")) },
    "invalid_aud" => -> { privacy_token(privacy_claims(aud: "flavortown")) },
    "expired" => -> { privacy_token(privacy_claims(now: Time.now.to_i - 400)) },
    "invalid_lifetime" => -> { privacy_token(privacy_claims(exp: Time.now.to_i + 600)) },
    "invalid_iat" => -> { privacy_token(privacy_claims(now: Time.now.to_i + 120)) },
    "invalid_action" => -> { privacy_token(privacy_claims(action: "nuke")) },
    "invalid_dry_run" => -> { privacy_token(privacy_claims(dry_run: "false")) },
    "invalid_subject" => -> { privacy_token(privacy_claims(subject: { emails: "someone@example.com" })) }
  }.each do |code, token|
    it "rejects with #{code}" do
      expect { described_class.verify!(instance_exec(&token)) }
        .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq(code) }
    end
  end

  it "reports jwks_unavailable when the hub's keys can't be fetched" do
    stub_request(:get, Privacy::Token::JWKS_URL).to_return(status: 502)

    expect { described_class.verify!(privacy_token) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("jwks_unavailable") }
  end

  it "accepts each jti once" do
    jti = SecureRandom.uuid

    expect(described_class.first_use!(jti)).to be(true)
    expect(described_class.first_use!(jti)).to be(false)
  end
end
