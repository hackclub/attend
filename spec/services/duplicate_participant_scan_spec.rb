require "rails_helper"

RSpec.describe DuplicateParticipantScan do
  def participant(email:, user: nil, first: "Rowan", last: "Fairweather", dob: "2009-07-17", **attrs)
    create(:participant, email: email, user: user, legal_first_name: first, legal_last_name: last,
           date_of_birth: dob, **attrs)
  end

  # Scans are scoped to the addresses each example creates: the shared test
  # database carries rows from other runs whose factory-sequenced addresses
  # collide, so a table-wide assertion here would be flaky.
  def scan_for(*emails)
    described_class.new(emails: emails)
  end

  it "ignores addresses held by a single participant" do
    participant(email: "solo@example.com")

    expect(scan_for("solo@example.com").duplicate_emails).to be_empty
  end

  it "matches duplicates regardless of the case the address was stored in" do
    participant(email: "Rowan@example.com")
    participant(email: "rowan@example.com")

    expect(scan_for("rowan@example.com").duplicate_emails).to eq([ "rowan@example.com" ])
  end

  describe "picking the row to keep" do
    it "keeps the row the sign-in account points at, even with no registrations" do
      user = User.create!(email: "rowan@example.com", name: "Rowan")
      shell = participant(email: user.email, user: user)
      imported = participant(email: user.email)
      create(:participant_event, participant: imported)

      group = scan_for("rowan@example.com").groups.sole

      expect(group.primary).to eq(shell)
      expect(group.duplicates).to eq([ imported ])
    end

    it "prefers the linked row holding the most registrations when several are linked" do
      user = User.create!(email: "rowan@example.com", name: "Rowan")
      empty = participant(email: user.email, user: user)
      registered = participant(email: user.email, user: user)
      create(:participant_event, participant: registered)

      group = scan_for("rowan@example.com").groups.sole

      expect(group.primary).to eq(registered)
      expect(group.duplicates).to eq([ empty ])
    end

    it "falls back to the most-registered row when no account is linked" do
      bare = participant(email: "rowan@example.com")
      registered = participant(email: "rowan@example.com")
      create(:participant_event, participant: registered)

      expect(scan_for("rowan@example.com").groups.sole.primary).to eq(registered)
    end
  end

  describe "flags" do
    it "treats spacing, case and swapped preferred names as the same person" do
      participant(email: "rowan@example.com", first: "Rowan", last: "Fairweather")
      participant(email: "rowan@example.com", first: "rowan ", last: " fairweather")

      expect(scan_for("rowan@example.com").groups.sole).to be_safe
    end

    it "accepts a differing surname when the first name matches" do
      participant(email: "wren@example.com", first: "Wren", last: "Ashdown")
      participant(email: "wren@example.com", first: "Wren", last: "Ashby")

      expect(scan_for("wren@example.com").groups.sole.flags).to be_empty
    end

    it "flags rows whose names don't agree at all" do
      participant(email: "shared@example.com", first: "Rowan", last: "Ashdown")
      participant(email: "shared@example.com", first: "Sasha", last: "Ashdown")

      expect(scan_for("shared@example.com").groups.sole.flags).to include("name mismatch")
    end

    it "flags a differing date of birth" do
      participant(email: "rowan@example.com", dob: "2009-07-17")
      participant(email: "rowan@example.com", dob: "2009-06-05")

      expect(scan_for("rowan@example.com").groups.sole.flags).to include("date of birth mismatch")
    end

    it "flags rows linked to two different accounts" do
      one = User.create!(email: "rowan@example.com", name: "One")
      two = User.create!(email: "rowan-alt@example.com", name: "Two")
      participant(email: "rowan@example.com", user: one)
      participant(email: "rowan@example.com", user: two)

      expect(scan_for("rowan@example.com").groups.sole.flags).to include("linked to different accounts")
    end

    it "flags a duplicate that owns the public profile the merge would delete" do
      user = User.create!(email: "rowan@example.com", name: "Rowan")
      participant(email: user.email, user: user)
      registered = participant(email: user.email, public_profile_enabled: true, public_profile_slug: "rowan")
      create(:participant_event, participant: registered)

      expect(scan_for("rowan@example.com").groups.sole.flags).to include("duplicate owns the public profile")
    end

    it "does not flag the profile when the surviving row owns it" do
      user = User.create!(email: "rowan@example.com", name: "Rowan")
      participant(email: user.email, user: user, public_profile_enabled: true, public_profile_slug: "rowan")
      participant(email: user.email)

      expect(scan_for("rowan@example.com").groups.sole.flags).to be_empty
    end
  end

  describe "restricting to a reviewed list" do
    it "scans only the addresses asked for and reports the rest" do
      participant(email: "rowan@example.com")
      participant(email: "rowan@example.com")
      participant(email: "other@example.com")
      participant(email: "other@example.com")

      scan = described_class.new(emails: [ " Rowan@example.com ", "already-merged@example.com" ])

      expect(scan.duplicate_emails).to eq([ "rowan@example.com" ])
      expect(scan.groups.map(&:email)).to eq([ "rowan@example.com" ])
      expect(scan.missing_emails).to eq([ "already-merged@example.com" ])
    end
  end
end
