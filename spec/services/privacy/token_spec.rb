require "rails_helper"

RSpec.describe Privacy::Token do
  include ActiveSupport::Testing::TimeHelpers

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
    "invalid_lifetime" + " (exp before iat)" => -> { privacy_token(privacy_claims(iat: Time.now.to_i, exp: Time.now.to_i - 10)) },
    "invalid_jti" => -> { privacy_token(privacy_claims(jti: "")) },
    "invalid_request_id" => -> { privacy_token(privacy_claims(request_id: 42)) },
    "invalid_iat" => -> { privacy_token(privacy_claims(now: Time.now.to_i + 120)) },
    "invalid_action" => -> { privacy_token(privacy_claims(action: "nuke")) },
    "invalid_dry_run" => -> { privacy_token(privacy_claims(dry_run: "false")) },
    "invalid_subject" => -> { privacy_token(privacy_claims(subject: { emails: "someone@example.com" })) }
  }.each do |code, token|
    it "rejects with #{code}" do
      expect { described_class.verify!(instance_exec(&token)) }
        .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq(code.split(" ").first) }
    end
  end

  it "reports jwks_unavailable when the hub's keys can't be fetched" do
    stub_request(:get, Privacy::Token::JWKS_URL).to_return(status: 502)

    expect { described_class.verify!(privacy_token) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("jwks_unavailable") }
  end

  {
    "two segments" => "abc.def",
    "a header that isn't base64" => "!!!.e30.e30",
    "a header that isn't JSON" => "#{Base64.urlsafe_encode64("not json", padding: false)}.e30.e30",
    "a header that's a JSON array" => "#{Base64.urlsafe_encode64("[]", padding: false)}.e30.e30"
  }.each do |shape, token|
    it "rejects #{shape} as malformed" do
      expect { described_class.verify!(token) }
        .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("malformed") }
    end
  end

  it "rejects a signed token whose claims aren't JSON as malformed" do
    header = Base64.urlsafe_encode64({ alg: "ES256", typ: "JWT", kid: PrivacyHubHelpers::PRIVACY_HUB_KID }.to_json, padding: false)
    signing_input = "#{header}.#{Base64.urlsafe_encode64("not json", padding: false)}"
    r, s = OpenSSL::ASN1.decode(PrivacyHubHelpers::PRIVACY_HUB_KEY.sign("SHA256", signing_input)).value.map { |int| int.value.to_s(2).rjust(32, "\x00".b) }

    expect { described_class.verify!("#{signing_input}.#{Base64.urlsafe_encode64(r + s, padding: false)}") }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("malformed") }
  end

  it "allows the clock leeway at its boundary and not past it" do
    now = Time.now.to_i
    edge = privacy_claims(now: now - 300 - Privacy::Token::LEEWAY)
    past = privacy_claims(now: now - 300 - Privacy::Token::LEEWAY - 1)

    expect(described_class.verify!(privacy_token(edge), now:).request_id).to eq(edge[:request_id])
    expect { described_class.verify!(privacy_token(past), now:) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("expired") }
  end

  {
    "isn't JSON" => "nope",
    "is empty" => { keys: [] }.to_json,
    "has only unsupported keys" => { keys: [ { kty: "RSA", kid: "rsa" }, { kty: "EC", crv: "P-384", kid: "wrong-curve" } ] }.to_json,
    "has no key list" => { keys: "nope" }.to_json,
    "has a key that won't decode" => { keys: [ { kty: "EC", crv: "P-256", kid: "bad", x: "!!", y: "!!" } ] }.to_json,
    "has a point that isn't on the curve" => { keys: [ { kty: "EC", crv: "P-256", kid: "bad", x: Base64.urlsafe_encode64("\x01" * 32, padding: false), y: Base64.urlsafe_encode64("\x01" * 32, padding: false) } ] }.to_json
  }.each do |shape, body|
    it "reports jwks_unavailable when the key set #{shape}" do
      stub_request(:get, Privacy::Token::JWKS_URL).to_return(status: 200, body:)

      expect { described_class.verify!(privacy_token) }
        .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("jwks_unavailable") }
    end
  end

  it "does not cache an empty key set, allowing an immediate retry after recovery" do
    stub_request(:get, Privacy::Token::JWKS_URL).to_return(status: 200, body: { keys: [] }.to_json)
    expect { described_class.verify!(privacy_token) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("jwks_unavailable") }

    stub_privacy_jwks

    expect(described_class.verify!(privacy_token).action).to eq("delete")
  end

  it "reports jwks_unavailable when the only key has a blank kid" do
    stub_privacy_jwks(kid: "")

    expect { described_class.verify!(privacy_token) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("jwks_unavailable") }
  end

  it "refetches the keys for an unknown kid once the throttle allows, picking up a rotated key" do
    rotated = OpenSSL::PKey::EC.generate("prime256v1")
    described_class.verify!(privacy_token)
    stub_privacy_jwks(key: rotated, kid: "rotated")

    expect { described_class.verify!(privacy_token(privacy_claims, key: rotated, header: { kid: "rotated" })) }
      .to raise_error(Privacy::Token::Invalid) { |error| expect(error.code).to eq("unknown_kid") }

    travel(Privacy::Token::UNKNOWN_KID_REFETCH + 1) do
      expect(described_class.verify!(privacy_token(privacy_claims, key: rotated, header: { kid: "rotated" })).action).to eq("delete")
    end
  end

  it "accepts each jti once" do
    jti = SecureRandom.uuid

    expect(described_class.first_use!(jti)).to be(true)
    expect(described_class.first_use!(jti)).to be(false)
  end
end
