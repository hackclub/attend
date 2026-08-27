require "rails_helper"

RSpec.describe DuplicateParticipantScan do
  def participant(email:, user: nil, first: "Afnan", last: "Rahman", dob: "2009-07-17", **attrs)
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
    participant(email: "Afnan@example.com")
    participant(email: "afnan@example.com")

    expect(scan_for("afnan@example.com").duplicate_emails).to eq([ "afnan@example.com" ])
  end

  describe "picking the row to keep" do
    it "keeps the row the sign-in account points at, even with no registrations" do
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      shell = participant(email: user.email, user: user)
      imported = participant(email: user.email)
      create(:participant_event, participant: imported)

      group = scan_for("afnan@example.com").groups.sole

      expect(group.primary).to eq(shell)
      expect(group.duplicates).to eq([ imported ])
    end

    it "prefers the linked row holding the most registrations when several are linked" do
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      empty = participant(email: user.email, user: user)
      registered = participant(email: user.email, user: user)
      create(:participant_event, participant: registered)

      group = scan_for("afnan@example.com").groups.sole

      expect(group.primary).to eq(registered)
      expect(group.duplicates).to eq([ empty ])
    end

    it "falls back to the most-registered row when no account is linked" do
      bare = participant(email: "afnan@example.com")
      registered = participant(email: "afnan@example.com")
      create(:participant_event, participant: registered)

      expect(scan_for("afnan@example.com").groups.sole.primary).to eq(registered)
    end
  end

  describe "flags" do
    it "treats spacing, case and swapped preferred names as the same person" do
      participant(email: "afnan@example.com", first: "Afnan", last: "Rahman")
      participant(email: "afnan@example.com", first: "afnan ", last: " rahman")

      expect(scan_for("afnan@example.com").groups.sole).to be_safe
    end

    it "accepts a differing surname when the first name matches" do
      participant(email: "jenin@example.com", first: "Julian", last: "Henin")
      participant(email: "jenin@example.com", first: "Julian", last: "Jenin")

      expect(scan_for("jenin@example.com").groups.sole.flags).to be_empty
    end

    it "flags rows whose names don't agree at all" do
      participant(email: "family@example.com", first: "Hiba", last: "Malik")
      participant(email: "family@example.com", first: "Hunain", last: "Malik")

      expect(scan_for("family@example.com").groups.sole.flags).to include("name mismatch")
    end

    it "flags a differing date of birth" do
      participant(email: "afnan@example.com", dob: "2009-07-17")
      participant(email: "afnan@example.com", dob: "2009-06-05")

      expect(scan_for("afnan@example.com").groups.sole.flags).to include("date of birth mismatch")
    end

    it "flags rows linked to two different accounts" do
      one = User.create!(email: "afnan@example.com", name: "One")
      two = User.create!(email: "afnan-alt@example.com", name: "Two")
      participant(email: "afnan@example.com", user: one)
      participant(email: "afnan@example.com", user: two)

      expect(scan_for("afnan@example.com").groups.sole.flags).to include("linked to different accounts")
    end

    it "flags a duplicate that owns the public profile the merge would delete" do
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      participant(email: user.email, user: user)
      registered = participant(email: user.email, public_profile_enabled: true, public_profile_slug: "afnan")
      create(:participant_event, participant: registered)

      expect(scan_for("afnan@example.com").groups.sole.flags).to include("duplicate owns the public profile")
    end

    it "does not flag the profile when the surviving row owns it" do
      user = User.create!(email: "afnan@example.com", name: "Afnan")
      participant(email: user.email, user: user, public_profile_enabled: true, public_profile_slug: "afnan")
      participant(email: user.email)

      expect(scan_for("afnan@example.com").groups.sole.flags).to be_empty
    end
  end

  describe "restricting to a reviewed list" do
    it "scans only the addresses asked for and reports the rest" do
      participant(email: "afnan@example.com")
      participant(email: "afnan@example.com")
      participant(email: "other@example.com")
      participant(email: "other@example.com")

      scan = described_class.new(emails: [ " Afnan@example.com ", "already-merged@example.com" ])

      expect(scan.duplicate_emails).to eq([ "afnan@example.com" ])
      expect(scan.groups.map(&:email)).to eq([ "afnan@example.com" ])
      expect(scan.missing_emails).to eq([ "already-merged@example.com" ])
    end
  end
end
