require "rails_helper"

RSpec.describe "Api::V1::TokenRevocations", type: :request do
  def revoke(token)
    post "/api/v1/tokens/revoke", params: { token: token }
  end

  it "returns success: false for a bogus token and does nothing" do
    expect {
      revoke("attn_not-a-real-token")
    }.not_to have_enqueued_mail(ApiTokenMailer, :revoked)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("success" => false)
  end

  it "returns success: false for a blank token" do
    revoke("")
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("success" => false)
  end

  it "requires no Authorization header — the token itself is the credential" do
    user = create(:user)
    event = create(:event)
    token = EventApiToken.generate_for(event, user: user, name: "attend-ci")

    post "/api/v1/tokens/revoke", params: { token: token.token }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["success"]).to be(true)
    expect(body["owner_email"]).to eq(user.email)
    expect(body["key_name"]).to include("attend-ci").and include(event.name)
    expect(EventApiToken.find_by_token(token.token)).to be_nil
  end

  describe "global API token" do
    let(:user) { create(:user).tap { |u| u.update!(global_role: :global_admin) } }

    it "revokes the token and emails its creator" do
      token = GlobalApiToken.generate_for(user, name: "leo@attend-ci").token

      expect { revoke(token) }
        .to have_enqueued_mail(ApiTokenMailer, :revoked)
        .with(a_hash_including(params: a_hash_including(email: user.email, token_kind: "global")))

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["owner_email"]).to eq(user.email)
      expect(GlobalApiToken.find_by_token(token)).to be_nil
    end
  end

  describe "event API token" do
    let(:user) { create(:user) }
    let(:event) { create(:event) }

    it "revokes the token and emails its creator" do
      token = EventApiToken.generate_for(event, user: user, name: "attend-ci").token

      expect { revoke(token) }
        .to have_enqueued_mail(ApiTokenMailer, :revoked)
        .with(a_hash_including(params: a_hash_including(email: user.email, token_kind: "event")))

      expect(response).to have_http_status(:ok)
      expect(EventApiToken.find_by_token(token)).to be_nil
    end

    it "falls back to event admins when the token has no creator" do
      admin = create(:user)
      EventRoleAssignment.create!(event: event, user: admin, role: :event_admin)
      token = EventApiToken.generate_for(event, user: nil, name: "attend-ci")
      token.update!(user: nil)

      expect { revoke(token.token) }
        .to have_enqueued_mail(ApiTokenMailer, :revoked)
        .with(a_hash_including(params: a_hash_including(email: admin.email)))

      expect(JSON.parse(response.body)["owner_email"]).to eq(admin.email)
    end
  end

  describe "legacy event key" do
    let(:event) { create(:event) }

    it "clears the key and emails event admins" do
      admin = create(:user)
      EventRoleAssignment.create!(event: event, user: admin, role: :event_admin)
      key = event.generate_api_key!

      expect { revoke(key) }
        .to have_enqueued_mail(ApiTokenMailer, :revoked)
        .with(a_hash_including(params: a_hash_including(email: admin.email)))

      expect(event.reload.api_key_set?).to be(false)
    end
  end
end
