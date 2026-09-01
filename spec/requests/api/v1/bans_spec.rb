require "rails_helper"

RSpec.describe "Api::V1::Bans", type: :request do
  let(:admin) { create(:user, global_role: :global_admin) }
  let(:headers) { { "Authorization" => "Bearer #{MobileToken.generate_for(admin).token}" } }

  def json
    JSON.parse(response.body)
  end

  it "creates an indefinite ban from a single email" do
    post api_v1_bans_path, params: { email: "Blocked@Example.com", reason: "Test" }, headers: headers

    expect(response).to have_http_status(:created)
    expect(json["ban"]["emails"]).to eq([ "blocked@example.com" ])
    expect(json["ban"]["status"]).to eq("Indefinite")
    expect(json["ban"]["created_by"]["id"]).to eq(admin.id)
    expect(Ban.banned?("blocked@example.com")).to be(true)
  end

  it "puts every email for one person on the same ban" do
    post api_v1_bans_path,
      params: { emails: [ "one@example.com", " ONE@example.com ", "two@example.com" ] },
      headers: headers

    expect(response).to have_http_status(:created)
    expect(Ban.count).to eq(1)
    expect(json["ban"]["emails"]).to eq([ "one@example.com", "two@example.com" ])
  end

  it "honours an expiry" do
    post api_v1_bans_path,
      params: { email: "temporary@example.com", expires_at: 3.days.from_now.iso8601 },
      headers: headers

    expect(response).to have_http_status(:created)
    expect(json["ban"]["status"]).to eq("Active")
    expect(Ban.last.expires_at).to be_within(1.second).of(3.days.from_now)
  end

  # A typo here would otherwise be dropped and quietly create a permanent ban.
  it "rejects an unparseable expiry rather than banning indefinitely" do
    post api_v1_bans_path,
      params: { email: "temporary@example.com", expires_at: "next tuesday-ish" },
      headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to match(/expires_at/)
    expect(Ban.count).to eq(0)
  end

  it "rejects a missing email" do
    post api_v1_bans_path, params: { reason: "No email" }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to match(/at least one email/i)
  end

  it "rejects a malformed email" do
    post api_v1_bans_path, params: { email: "not-an-email" }, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to match(/invalid email format/i)
    expect(Ban.count).to eq(0)
  end

  # ban_emails.email is globally unique, so the caller needs the existing
  # record's id to act on it rather than a bare validation failure.
  it "returns the existing ban when the email is already listed" do
    existing = create(:ban, email: "repeat@example.com")

    post api_v1_bans_path, params: { email: "REPEAT@example.com" }, headers: headers

    expect(response).to have_http_status(:conflict)
    expect(json["error"]).to match(/already on the ban list/i)
    expect(json["bans"].map { |ban| ban["id"] }).to eq([ existing.id ])
    expect(Ban.count).to eq(1)
  end

  it "reports a revoked ban as the conflict, since its email stays reserved" do
    existing = create(:ban, email: "revoked@example.com")
    existing.revoke!(by: admin)

    post api_v1_bans_path, params: { email: "revoked@example.com" }, headers: headers

    expect(response).to have_http_status(:conflict)
    expect(json["bans"].first["status"]).to eq("Revoked")
  end

  it "attributes the ban in the audit log and version history" do
    post api_v1_bans_path, params: { email: "audited@example.com" }, headers: headers

    ban = Ban.last
    log = AuditLog.for_record(ban).last
    expect(log.actor).to eq(admin)
    expect(log.metadata["emails"]).to eq([ "audited@example.com" ])
    expect(ban.versions.last.whodunnit).to eq(admin.id.to_s)
  end

  describe "authorization" do
    it "refuses a non-admin user" do
      staff = create(:user)
      post api_v1_bans_path,
        params: { email: "blocked@example.com" },
        headers: { "Authorization" => "Bearer #{MobileToken.generate_for(staff).token}" }

      expect(response).to have_http_status(:forbidden)
      expect(Ban.count).to eq(0)
    end

    it "refuses an event API key, which has no user behind it" do
      api_key = create(:event).generate_api_key!
      post api_v1_bans_path,
        params: { email: "blocked@example.com" },
        headers: { "Authorization" => "Bearer #{api_key}" }

      expect(response).to have_http_status(:forbidden)
      expect(Ban.count).to eq(0)
    end

    it "refuses a request with no token" do
      post api_v1_bans_path, params: { email: "blocked@example.com" }

      expect(response).to have_http_status(:unauthorized)
      expect(Ban.count).to eq(0)
    end

    it "accepts a global API token" do
      token = GlobalApiToken.generate_for(admin).token
      post api_v1_bans_path,
        params: { email: "blocked@example.com" },
        headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:created)
    end
  end

  describe "token scoping" do
    def scoped_headers(scopes)
      { "Authorization" => "Bearer #{GlobalApiToken.generate_for(admin, scopes: scopes).token}" }
    end

    it "accepts a token scoped to bans:write" do
      post api_v1_bans_path, params: { email: "blocked@example.com" }, headers: scoped_headers([ "bans:write" ])

      expect(response).to have_http_status(:created)
      expect(Ban.banned?("blocked@example.com")).to be(true)
    end

    # The point of the scope: a leaked ban-list token must not read the
    # participant data the same global admin can reach interactively.
    it "refuses that token everywhere else, read-only endpoints included" do
      headers = scoped_headers([ "bans:write" ])

      get api_v1_events_path, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to match(/limited to: Add emails to the ban list/)

      get api_v1_me_path, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "leaves an unscoped token with its full access" do
      headers = { "Authorization" => "Bearer #{GlobalApiToken.generate_for(admin).token}" }

      get api_v1_events_path, headers: headers
      expect(response).to have_http_status(:ok)

      post api_v1_bans_path, params: { email: "blocked@example.com" }, headers: headers
      expect(response).to have_http_status(:created)
    end

    it "does not restrict a mobile token, which carries a signed-in human" do
      get api_v1_events_path, headers: headers

      expect(response).to have_http_status(:ok)
    end
  end
end
