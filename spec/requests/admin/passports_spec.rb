require "rails_helper"

RSpec.describe "Admin::Passports", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:global_admin) { create(:user, global_role: "global_admin") }
  let(:owner) { create(:user, name: "Passport Owner") }

  before { sign_in global_admin }

  describe "POST /admin/users/:user_id/passports" do
    it "creates a pending passport and returns its private token only in JSON" do
      post admin_user_passports_path(owner)

      expect(response).to have_http_status(:created)
      passport = owner.passports.pending.sole
      expect(response.parsed_body).to include(
        "id" => passport.id,
        "token" => passport.token,
        "serial_number" => passport.serial_number
      )
    end

    it "reuses the newest pending passport" do
      pending = create(:passport, user: owner)

      expect {
        post admin_user_passports_path(owner)
      }.not_to change(Passport, :count)

      expect(response.parsed_body.fetch("id")).to eq(pending.id)
    end
  end

  describe "POST /admin/users/:user_id/passports/:id/confirm" do
    it "pairs an exact token and writes a token-free audit record" do
      passport = create(:passport, user: owner)

      post confirm_admin_user_passport_path(owner, passport),
        params: { passport_token: passport.token }

      expect(response).to have_http_status(:ok)
      expect(passport.reload).to be_active
      expect(passport.paired_by).to eq(global_admin)

      audit = AuditLog.passport_pair.last
      expect(audit.record).to eq(passport)
      expect(audit.actor).to eq(global_admin)
      expect(audit.metadata).to include("serial_number" => passport.serial_number, "user_id" => owner.id)
      expect(audit.metadata.to_json).not_to include(passport.token)
    end

    it "rejects a mismatched token without pairing" do
      passport = create(:passport, user: owner)

      post confirm_admin_user_passport_path(owner, passport),
        params: { passport_token: SecureRandom.uuid }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Passport token mismatch")
      expect(passport.reload).to be_pending
    end

    it "cannot confirm a passport belonging to another user" do
      passport = create(:passport)

      post confirm_admin_user_passport_path(owner, passport),
        params: { passport_token: passport.token }

      expect(response).to redirect_to(root_path)
      expect(passport.reload).to be_pending
    end
  end

  describe "DELETE /admin/users/:user_id/passports/:id" do
    it "revokes an active passport and records the public serial in the audit" do
      passport = create(:passport, :active, user: owner)

      delete admin_user_passport_path(owner, passport)

      expect(response).to redirect_to(admin_user_path(owner))
      expect(passport.reload).to be_revoked
      expect(passport.revoked_by).to eq(global_admin)
      audit = AuditLog.passport_revoke.last
      expect(audit.metadata).to include("serial_number" => passport.serial_number, "user_id" => owner.id)
      expect(audit.metadata.to_json).not_to include(passport.token)
    end
  end

  describe "authorization" do
    it "rejects event admins" do
      event_admin = create(:user)
      create(:event_role_assignment, user: event_admin, role: "event_admin")
      sign_in event_admin

      post admin_user_passports_path(owner)

      expect(response).to redirect_to(admin_root_path)
      expect(owner.passports).to be_empty
    end

    it "rejects ordinary users" do
      sign_in create(:user)

      post admin_user_passports_path(owner)

      expect(response).to redirect_to(root_path)
      expect(owner.passports).to be_empty
    end
  end

  describe "GET /admin/users/:id" do
    it "shows passport controls and public history without rendering private tokens" do
      active = create(:passport, :active, user: owner)
      revoked = create(:passport, :revoked, user: owner)

      get admin_user_path(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "Hack Club Passports",
        "Pair passport",
        active.serial_number,
        revoked.serial_number,
        "Active",
        "Revoked"
      )
      expect(response.body).not_to include(active.token, revoked.token)
    end
  end
end
