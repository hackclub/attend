require "rails_helper"

RSpec.describe User, type: :model do
  describe "encryption of Hack Club Auth PII" do
    let(:claims) do
      {
        "given_name" => "Sofia",
        "phone_number" => "+18025550143",
        "birthdate" => "2008-04-02",
        "address" => { "locality" => "Shelburne", "region" => "VT" }
      }
    end

    def raw_column(user, column)
      User.connection.select_value(
        User.sanitize_sql_array([ "SELECT #{column}::text FROM users WHERE id = ?", user.id ])
      )
    end

    it "stores oidc_claims as ciphertext but reads back the hash" do
      user = create(:user, oidc_claims: claims)

      raw = raw_column(user, :oidc_claims)
      expect(raw).not_to include("8025550143", "Shelburne", "2008-04-02")
      expect(raw).to include("\"p\":", "\"iv\":")
      expect(user.reload.oidc_claims).to eq(claims)
    end

    it "stores phone_number as ciphertext but reads back the number" do
      user = create(:user, phone_number: "+18025550143")

      expect(raw_column(user, :phone_number)).not_to include("8025550143")
      expect(user.reload.phone_number).to eq("+18025550143")
    end

    it "still reads legacy plaintext rows written before the backfill" do
      user = create(:user)
      user.update_columns(oidc_claims: claims, phone_number: "+18025550143")

      user.reload
      expect(user.oidc_claims).to eq(claims)
      expect(user.phone_number).to eq("+18025550143")
    end

    it "re-encrypts legacy rows the way encrypt_pii:backfill does" do
      user = create(:user)
      user.update_columns(oidc_claims: claims, phone_number: "+18025550143")
      user.reload

      # Mirrors lib/tasks/encrypt_pii_backfill.rake: mark dirty, save past validations.
      %i[oidc_claims phone_number].each { |attr| user.public_send("#{attr}_will_change!") }
      expect(user.save(validate: false)).to be(true)

      expect(raw_column(user, :oidc_claims)).not_to include("8025550143", "Shelburne")
      expect(raw_column(user, :phone_number)).not_to include("8025550143")
      expect(user.reload.oidc_claims).to eq(claims)
      expect(user.phone_number).to eq("+18025550143")
    end

    describe "#backfill_contact_from_claims!" do
      it "encrypts the phone number it copies out of the claims" do
        user = create(:user, oidc_claims: { "phone_number" => "+18025550143", "slack_id" => "U123ABC" })

        user.backfill_contact_from_claims!

        expect(user.reload.phone_number).to eq("+18025550143")
        expect(user.slack_user_id).to eq("U123ABC")
        expect(raw_column(user, :phone_number)).not_to include("8025550143")
      end

      it "does not clobber values the user set manually" do
        user = create(:user, phone_number: "+18025550100", slack_user_id: "UMANUAL",
                             oidc_claims: { "phone_number" => "+18025550143", "slack_id" => "U123ABC" })

        user.backfill_contact_from_claims!

        expect(user.reload.phone_number).to eq("+18025550100")
        expect(user.slack_user_id).to eq("UMANUAL")
      end

      it "is not blocked by a record that fails validation" do
        user = create(:user, oidc_claims: { "phone_number" => "+18025550143" })
        user.update_column(:email, "")

        expect { user.backfill_contact_from_claims! }.not_to raise_error
        expect(user.reload.phone_number).to eq("+18025550143")
      end
    end
  end

  describe "#sync_slack_id_to_participant" do
    let(:user) { create(:user, oidc_claims: { "slack_id" => "U123ABC" }) }
    let!(:participant) { create(:participant, user: user) }

    it "copies the slack_id from oidc_claims to the participant" do
      user.sync_slack_id_to_participant
      expect(participant.reload.slack_user_id).to eq("U123ABC")
    end

    it "does not raise when the participant has otherwise-invalid data" do
      # Legacy records can hold a phone that fails the current validation;
      # syncing the Slack ID at sign-in must not be blocked by that.
      participant.update_column(:phone, "not-a-phone")

      expect { user.sync_slack_id_to_participant }.not_to raise_error
      expect(participant.reload.slack_user_id).to eq("U123ABC")
    end

    it "does nothing when there is no slack_id claim" do
      user.update!(oidc_claims: {})
      user.sync_slack_id_to_participant
      expect(participant.reload.slack_user_id).to be_nil
    end
  end

  describe "#sync_email_to_participant" do
    let(:user) { create(:user, email: "new@example.com") }
    let!(:participant) { create(:participant, user: user, email: "old@example.com") }

    it "copies the user's email to the participant" do
      user.sync_email_to_participant
      expect(participant.reload.email).to eq("new@example.com")
    end

    it "does not raise when the participant has otherwise-invalid data" do
      participant.update_column(:phone, "not-a-phone")

      expect { user.sync_email_to_participant }.not_to raise_error
      expect(participant.reload.email).to eq("new@example.com")
    end

    it "does nothing when there is no linked participant" do
      participant.destroy!
      expect { user.reload.sync_email_to_participant }.not_to raise_error
    end
  end

  describe ".from_omniauth" do
    # Mirrors what OmniAuth::Strategies::HackClub#info builds, so this covers
    # the model half of the flow (see spec/lib/omniauth/strategies for the rest).
    def auth_hash(raw_info)
      identity = raw_info["identity"] || {}
      email = raw_info["email"] || identity["primary_email"]
      first_name = raw_info["given_name"] || identity["first_name"]
      last_name = raw_info["family_name"] || identity["last_name"]
      OmniAuth::AuthHash.new(
        provider: "hack_club",
        uid: identity["id"],
        info: {
          email: email,
          first_name: first_name,
          last_name: last_name,
          name: raw_info["name"] ||
            [ first_name, last_name ].compact.join(" ").presence ||
            email&.split("@")&.first
        },
        extra: { raw_info: raw_info }
      )
    end

    let(:identity) do
      {
        "id" => "ident!ABC123",
        "primary_email" => "sofiacegan@gmail.com",
        "slack_id" => "U07BLJ1MBEE",
        "verification_status" => "verified"
      }
    end

    it "uses the OIDC name claims rather than the email local part" do
      user = User.from_omniauth(auth_hash(
        "identity" => identity,
        "name" => "Sofia Cegan",
        "given_name" => "Sofia",
        "family_name" => "Cegan",
        "birthdate" => "2008-04-02",
        "address" => { "street_address" => "15 Falls Rd", "locality" => "Shelburne", "region" => "VT", "postal_code" => "05482", "country" => "US" }
      ))

      expect(user.name).to eq("Sofia Cegan")
      expect(user.oidc_claims).to include(
        "given_name" => "Sofia",
        "family_name" => "Cegan",
        "preferred_name" => "Sofia",
        "birthdate" => "2008-04-02",
        "slack_id" => "U07BLJ1MBEE"
      )
      expect(user.oidc_claims["address"]).to include("locality" => "Shelburne")
    end

    it "prefers the identity record's names when HCA returns both" do
      user = User.from_omniauth(auth_hash(
        "identity" => identity.merge("first_name" => "Sof", "last_name" => "Cegan"),
        "given_name" => "Sofia",
        "family_name" => "Cegan"
      ))

      expect(user.oidc_claims).to include("given_name" => "Sof", "preferred_name" => "Sof")
    end

    it "still creates the user when no name claims come back" do
      user = User.from_omniauth(auth_hash("identity" => identity))

      expect(user.name).to eq("sofiacegan")
      expect(user.oidc_claims).not_to have_key("given_name")
    end

    it "stores a normalized email on creation" do
      user = User.from_omniauth(auth_hash(
        "identity" => identity.merge("primary_email" => "  SofiaCegan@Gmail.COM ")
      ))

      expect(user.email).to eq("sofiacegan@gmail.com")
    end

    it "finds an existing user when HCA returns the email with different casing" do
      existing = create(:user, email: "sofiacegan@gmail.com")

      expect {
        found = User.from_omniauth(auth_hash(
          "identity" => identity.merge("primary_email" => "SofiaCegan@Gmail.com")
        ))
        expect(found.id).to eq(existing.id)
      }.not_to change(User, :count)

      expect(existing.reload.hack_club_account_id).to eq(identity["id"])
    end

    it "recovers when a concurrent request creates the user between lookup and insert" do
      winner = nil
      allow(User).to receive(:create!).and_wrap_original do |original, *args|
        # Simulate the racing request committing first: the row already
        # exists by the time this insert hits the unique index.
        winner = original.call(*args)
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint \"index_users_on_email\""
      end

      user = User.from_omniauth(auth_hash("identity" => identity))

      expect(user.id).to eq(winner.id)
      expect(user.email).to eq("sofiacegan@gmail.com")
    end

    it "re-raises when creation fails for reasons other than a duplicate" do
      expect {
        User.from_omniauth(auth_hash("identity" => identity.merge("primary_email" => nil)))
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    describe "when the HCA email changed" do
      let!(:account) do
        create(:user, email: "sofiaold@gmail.com", hack_club_account_id: identity["id"],
                      sign_in_count: 3)
      end

      it "updates the email and reports the previous one" do
        user = User.from_omniauth(auth_hash("identity" => identity))

        expect(user.id).to eq(account.id)
        expect(user.email).to eq("sofiacegan@gmail.com")
        expect(user.previous_email_at_sign_in).to eq("sofiaold@gmail.com")
      end

      it "carries the new email onto the linked participant" do
        participant = create(:participant, user: account, email: "sofiaold@gmail.com")

        User.from_omniauth(auth_hash("identity" => identity))

        expect(participant.reload.email).to eq("sofiacegan@gmail.com")
      end

      context "when the new email belongs to a placeholder created by a staff invite" do
        let(:event) { create(:event) }
        let!(:placeholder) { create(:user, email: "sofiacegan@gmail.com") }
        let!(:invited_role) do
          EventRoleAssignment.create!(user: placeholder, event: event, role: "event_admin")
        end

        it "absorbs the placeholder: takes its email and role assignments" do
          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(user.id).to eq(account.id)
          expect(user.email).to eq("sofiacegan@gmail.com")
          expect(user.previous_email_at_sign_in).to eq("sofiaold@gmail.com")
          expect(invited_role.reload.user_id).to eq(account.id)
          expect(user.event_admin_for?(event)).to be(true)
          expect(User.exists?(placeholder.id)).to be(false)
        end

        it "drops assignments the real account already has instead of duplicating" do
          EventRoleAssignment.create!(user: account, event: event, role: "event_admin")

          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(user.email).to eq("sofiacegan@gmail.com")
          expect(EventRoleAssignment.where(event: event, role: "event_admin").pluck(:user_id))
            .to eq([ account.id ])
          expect(User.exists?(placeholder.id)).to be(false)
        end

        it "transfers series role assignments" do
          assignment = create(:series_role_assignment, user: placeholder)

          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(assignment.reload.user_id).to eq(user.id)
        end

        it "promotes the global role granted to the placeholder" do
          placeholder.update!(global_role: :global_admin)

          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(user.reload.global_admin?).to be(true)
        end

        it "does not demote the real account's global role" do
          account.update!(global_role: :global_admin)
          placeholder.update!(global_role: :read_only)

          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(user.reload.global_admin?).to be(true)
        end
      end

      context "when the new email belongs to another active account" do
        let!(:other_account) do
          create(:user, email: "sofiacegan@gmail.com", hack_club_account_id: "ident!OTHER")
        end

        it "keeps the old email but still refreshes the claims" do
          user = User.from_omniauth(auth_hash("identity" => identity, "given_name" => "Sofia"))

          expect(user.id).to eq(account.id)
          expect(user.email).to eq("sofiaold@gmail.com")
          expect(user.previous_email_at_sign_in).to be_nil
          expect(user.oidc_claims).to include("given_name" => "Sofia")
          expect(other_account.reload.email).to eq("sofiacegan@gmail.com")
        end
      end

      context "when the placeholder has data that cannot be merged" do
        let!(:placeholder) { create(:user, email: "sofiacegan@gmail.com") }

        it "keeps the old email and does not break sign-in" do
          # A participant FK has no dependent rule, so the destroy raises and
          # the merge must roll back and degrade gracefully.
          create(:participant, user: placeholder)
          allow(Rails.logger).to receive(:error).and_call_original

          user = User.from_omniauth(auth_hash("identity" => identity))

          expect(user.id).to eq(account.id)
          expect(user.email).to eq("sofiaold@gmail.com")
          expect(User.exists?(placeholder.id)).to be(true)
        end
      end
    end
  end

  describe "#placeholder_account?" do
    it "is true for a user created by an admin invite" do
      expect(create(:user).placeholder_account?).to be(true)
    end

    it "is false once the account has a Hack Club account id" do
      expect(create(:user, hack_club_account_id: "ident!X").placeholder_account?).to be(false)
    end

    it "is false once the account has signed in" do
      expect(create(:user, sign_in_count: 1).placeholder_account?).to be(false)
    end
  end
end
