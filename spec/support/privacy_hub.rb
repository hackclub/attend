# Signs tokens the way the Hack Club privacy hub does, and serves the matching
# JWKS, so specs exercise the real verifier end to end.
module PrivacyHubHelpers
  PRIVACY_HUB_KEY = OpenSSL::PKey::EC.generate("prime256v1")
  PRIVACY_HUB_KID = "spec-key"

  def stub_privacy_jwks(key: PRIVACY_HUB_KEY, kid: PRIVACY_HUB_KID)
    point = key.public_key.to_octet_string(:uncompressed)
    jwk = { kty: "EC", crv: "P-256", alg: "ES256", use: "sig", kid:,
            x: Base64.urlsafe_encode64(point.byteslice(1, 32), padding: false),
            y: Base64.urlsafe_encode64(point.byteslice(33, 32), padding: false) }
    stub_request(:get, Privacy::Token::JWKS_URL).to_return(status: 200, body: { keys: [ jwk ] }.to_json)
  end

  def reset_privacy_jwks_cache
    Privacy::Token.instance_variable_set(:@keys, {})
    Privacy::Token.instance_variable_set(:@fetched_at, nil)
  end

  def privacy_claims(action: "delete", dry_run: true, emails: [], slack_id: nil, identity_id: nil, now: Time.now.to_i, **overrides)
    {
      iss: "hackclub-privacy", aud: "attend", iat: now, exp: now + 300,
      jti: SecureRandom.uuid, request_id: SecureRandom.uuid, action:, dry_run:,
      subject: { emails:, slack_id:, identity_id: }
    }.merge(overrides)
  end

  def privacy_token(claims = privacy_claims, key: PRIVACY_HUB_KEY, header: {})
    header = { alg: "ES256", typ: "JWT", kid: PRIVACY_HUB_KID }.merge(header)
    signing_input = [ header, claims ].map { |part| Base64.urlsafe_encode64(part.to_json, padding: false) }.join(".")
    der = key.sign("SHA256", signing_input)
    r, s = OpenSSL::ASN1.decode(der).value.map { |int| int.value.to_s(2).rjust(32, "\x00".b) }
    "#{signing_input}.#{Base64.urlsafe_encode64(r + s, padding: false)}"
  end
end

RSpec.configure do |config|
  config.include PrivacyHubHelpers
end
