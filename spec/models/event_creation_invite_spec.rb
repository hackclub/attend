require "rails_helper"

RSpec.describe EventCreationInvite, type: :model do
  let(:invitee) { create(:user, email: "organizer@example.com") }

  it "normalizes the address and gives the link two weeks" do
    invite = create(:event_creation_invite, email: "  Organizer@Example.com ")

    expect(invite.email).to eq("organizer@example.com")
    expect(invite.expires_at).to be_within(1.minute).of(14.days.from_now)
    expect(invite).to be_pending
  end

  it "refuses a second open invite for the same address" do
    create(:event_creation_invite, email: "organizer@example.com")
    duplicate = build(:event_creation_invite, email: "Organizer@example.com")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:email].first).to include("already has an open invite")
  end

  it "allows a new invite once the earlier one is used, revoked or expired" do
    create(:event_creation_invite, :revoked, email: "organizer@example.com")
    create(:event_creation_invite, :expired, email: "organizer@example.com")

    expect(build(:event_creation_invite, email: "organizer@example.com")).to be_valid
  end

  it "refuses an address on the conduct ban list" do
    create(:ban, email: "organizer@example.com")

    expect(build(:event_creation_invite, email: "organizer@example.com")).not_to be_valid
  end

  describe "#issue_token!" do
    it "stores only a digest, and each new link replaces the last" do
      invite = create(:event_creation_invite)
      first = invite.issue_token!
      second = invite.issue_token!

      expect(invite.token_digest).not_to include(second)
      expect(described_class.find_by_token(first)).to be_nil
      expect(described_class.find_by_token(second)).to eq(invite)
      expect(described_class.find_by_token("")).to be_nil
    end
  end

  describe "#accept!" do
    it "ties the invite to the account it was addressed to" do
      invite = create(:event_creation_invite, email: invitee.email)

      invite.accept!(invitee)

      expect(invite).to be_started
      expect(described_class.usable_by(invitee)).to contain_exactly(invite)
    end

    it "refuses any other account" do
      invite = create(:event_creation_invite, email: invitee.email)

      expect { invite.accept!(create(:user)) }.to raise_error(ArgumentError)
      expect(invite.reload).to be_pending
    end

    it "refuses an expired or revoked invite" do
      expired = create(:event_creation_invite, :expired, email: invitee.email)
      expect { expired.accept!(invitee) }.to raise_error(ActiveRecord::RecordInvalid)

      revoked = create(:event_creation_invite, :revoked, email: invitee.email)
      expect { revoked.accept!(invitee) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  it "stays used when its event is deleted" do
    invite = create(:event_creation_invite, :accepted, email: invitee.email)
    event = create(:event)
    invite.complete!(event)

    event.destroy!

    expect(invite.reload).to be_completed
    expect(described_class.usable_by(invitee)).to be_empty
  end
end
