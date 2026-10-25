require "rails_helper"

RSpec.describe GlobalApiToken, type: :model do
  let(:admin) { create(:user, global_role: :global_admin) }

  describe "scopes" do
    it "issues an unrestricted token when none are given" do
      token = described_class.generate_for(admin)

      expect(token.scopes).to eq([])
      expect(token).to be_unrestricted
    end

    # Tokens created before the column existed default to [], so they must keep
    # working everywhere rather than losing access on deploy.
    it "treats an unrestricted token as permitting every scope, named or not" do
      token = described_class.generate_for(admin)

      expect(token.permits?("bans:write")).to be(true)
      expect(token.permits?(nil)).to be(true)
    end

    it "permits only the scopes it holds" do
      token = described_class.generate_for(admin, scopes: [ "bans:write" ])

      expect(token).not_to be_unrestricted
      expect(token.permits?("bans:write")).to be(true)
      expect(token.permits?("something:else")).to be(false)
    end

    # A controller that declares no scope is full-access only, so a scoped
    # token must be refused there rather than falling through to allowed.
    it "refuses a nil scope once restricted" do
      token = described_class.generate_for(admin, scopes: [ "bans:write" ])

      expect(token.permits?(nil)).to be(false)
      expect(token.permits?("")).to be(false)
    end

    it "normalises and de-duplicates the requested scopes" do
      token = described_class.generate_for(admin, scopes: [ :"bans:write", "bans:write", "" ])

      expect(token.scopes).to eq([ "bans:write" ])
    end

    it "rejects an unknown scope" do
      expect { described_class.generate_for(admin, scopes: [ "bans:write", "everything" ]) }
        .to raise_error(ActiveRecord::RecordInvalid, /unknown values: everything/)
    end

    it "labels its scopes for display" do
      token = described_class.generate_for(admin, scopes: [ "bans:write" ])

      expect(token.scope_labels).to eq([ "Add emails to the ban list" ])
    end
  end
end
