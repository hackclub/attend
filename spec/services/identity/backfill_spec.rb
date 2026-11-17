require "rails_helper"

RSpec.describe Identity::Backfill do
  def run(apply: true, batch_size: 2)
    described_class.new(apply:, batch_size:).call
  end

  def addresses_of(person)
    person.email_addresses.pluck(:address)
  end

  describe "accounts" do
    it "creates one person per user, with their address as primary" do
      signed_in = create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin")
      placeholder = create(:user, email: "invited.staff@example.com")

      report = run

      expect(report[:users][:mechanical][:person_per_account]).to eq(2)
      expect(signed_in.reload.person).to be_present
      expect(placeholder.reload.person).to be_present
      expect(signed_in.person).not_to eq(placeholder.person)
      expect(signed_in.person.primary_email_address.address).to eq("robin.vale@example.com")
    end

    it "treats an address as verified only when the account has signed in through Hack Club Auth" do
      signed_in = create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin")
      placeholder = create(:user, email: "invited.staff@example.com")

      run

      expect(signed_in.reload.person.email_addresses.sole).to be_verified
      expect(placeholder.reload.person.email_addresses.sole).not_to be_verified
    end

    it "copies phones that cannot be compared in SQL, from the account and its training details" do
      user = create(:user, phone_number: "+12025550111")
      create(:training_profile, user:, phone_number: "(202) 555-0122")

      report = run

      expect(user.reload.person.phone_numbers.pluck(:number, :source))
        .to contain_exactly([ "+12025550111", "user" ], [ "+12025550122", "training_profile" ])
      expect(report[:phone_numbers][:mechanical][:created]).to eq(2)
    end

    it "keeps a second account's claim to an already verified address unverified, and files it" do
      first = create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!one", created_at: 2.days.ago)
      second = store_legacy_email(create(:user, hack_club_account_id: "ident!two"), "Robin.Vale@example.com")

      report = run

      verified = EmailAddress.where(address: "robin.vale@example.com").verified
      expect(verified.count).to eq(1)
      expect(EmailAddress.where(address: "robin.vale@example.com").count).to eq(2)
      expect(first.reload.person).not_to eq(second.reload.person)
      expect(report[:email_addresses][:needs_review][:verified_for_another_person]).to eq(1)
      expect(IdentityReview.where(category: "verified_email_conflict").count).to eq(1)
    end
  end

  describe "participants linked to an account" do
    let(:user) { create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin") }

    it "joins the account's person, keeping a different address as unverified" do
      participant = create(:participant, user:, email: "robin.old@example.com", phone: "+12025550133",
        legal_first_name: "Robin", legal_last_name: "Vale")

      report = run

      person = user.reload.person
      expect(participant.reload.person).to eq(person)
      expect(person.email_addresses.verified.pluck(:address)).to eq([ "robin.vale@example.com" ])
      expect(person.email_addresses.unverified.pluck(:address)).to eq([ "robin.old@example.com" ])
      expect(person.phone_numbers.pluck(:number)).to eq([ "+12025550133" ])
      expect(report[:participants][:mechanical][:linked_account]).to eq(1)
    end

    it "leaves an account's participants unattached when they disagree with each other" do
      first = create(:participant, user:, legal_first_name: "Robin", legal_last_name: "Vale")
      second = create(:participant, user:, legal_first_name: "Alder", legal_last_name: "Vale")

      report = run

      expect([ first, second ].map { |row| row.reload.person_id }).to all(be_nil)
      expect(user.reload.person.participants).to be_empty
      expect(report[:participants][:needs_review][:linked_account_rows_disagree]).to eq(2)
      review = IdentityReview.find_by!(category: "linked_participants")
      expect(review.participant_ids).to match_array([ first.id, second.id ])
      expect(review.reasons).to include("name mismatch")
    end
  end

  describe "participants found by address" do
    it "joins an unlinked participant to the account holding the same address, whatever its case" do
      user = create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin")
      participant = store_legacy_email(create(:participant), " Robin.Vale@Example.com")

      report = run

      expect(participant.reload.person).to eq(user.reload.person)
      expect(addresses_of(user.person)).to eq([ "robin.vale@example.com" ])
      expect(report[:participants][:mechanical][:email_matches_account]).to eq(1)
    end

    it "gives a participant nobody else matches a person of their own" do
      participant = create(:participant, email: "solo.attendee@example.com")

      report = run

      expect(addresses_of(participant.reload.person)).to eq([ "solo.attendee@example.com" ])
      expect(participant.person.email_addresses.sole).not_to be_verified
      expect(report[:participants][:mechanical][:single]).to eq(1)
    end

    it "joins same-address rows that agree into one person" do
      imported = create(:participant, email: "robin.vale@example.com", legal_first_name: "Robin", legal_last_name: "Vale")
      retyped = store_legacy_email(
        create(:participant, legal_first_name: "robin", legal_last_name: "VALE"), "Robin.Vale@example.com"
      )

      report = run

      expect(imported.reload.person).to be_present
      expect(retyped.reload.person).to eq(imported.person)
      expect(addresses_of(imported.person)).to eq([ "robin.vale@example.com" ])
      expect(report[:participants][:mechanical][:same_email_clean]).to eq(2)
    end

    it "never joins siblings registered under a parent's inbox" do
      older = create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale")
      younger = create(:participant, email: "family@example.com", legal_first_name: "Alder", legal_last_name: "Vale")

      report = run

      expect([ older, younger ].map { |row| row.reload.person_id }).to all(be_nil)
      expect(EmailAddress.where(address: "family@example.com")).to be_empty
      expect(report[:participants][:needs_review][:same_email_flagged]).to eq(2)
      expect(report[:participants][:mechanical]).to be_empty
      review = IdentityReview.find_by!(category: "participant_duplicates")
      expect(review.participant_ids).to match_array([ older.id, younger.id ])
    end

    it "never joins same-named rows whose dates of birth differ" do
      create(:participant, email: "family@example.com", date_of_birth: Date.new(2009, 3, 1))
      create(:participant, email: "family@example.com", date_of_birth: Date.new(2011, 6, 9))

      report = run

      expect(Participant.where.not(person_id: nil)).to be_empty
      expect(report[:participants][:needs_review][:same_email_flagged]).to eq(2)
      expect(IdentityReview.sole.reasons).to include("date of birth mismatch")
    end

    it "never joins children to a parent's account because they share its address" do
      parent = create(:user, email: "family@example.com", hack_club_account_id: "ident!parent")
      children = [
        create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale"),
        create(:participant, email: "family@example.com", legal_first_name: "Alder", legal_last_name: "Vale")
      ]

      report = run

      expect(children.map { |row| row.reload.person_id }).to all(be_nil)
      expect(parent.reload.person.participants).to be_empty
      expect(report[:participants][:needs_review][:email_matches_account_flagged]).to eq(2)
      expect(IdentityReview.find_by!(category: "participant_account_email").user_ids).to eq([ parent.id ])
    end

    it "checks a row against the participant the account already holds under another address" do
      parent = create(:user, email: "family@example.com", hack_club_account_id: "ident!parent")
      own = create(:participant, user: parent, email: "morgan.vale@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")
      child = create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale")

      report = run

      expect(own.reload.person).to eq(parent.reload.person)
      expect(child.reload.person_id).to be_nil
      expect(report[:participants][:needs_review][:email_matches_account_flagged]).to eq(1)
    end

    it "does not join rows linked to different accounts" do
      first = create(:participant, email: "shared@example.com", user: create(:user, email: "one@example.com"))
      second = create(:participant, email: "shared@example.com", user: create(:user, email: "two@example.com"))
      unlinked = create(:participant, email: "shared@example.com")

      report = run

      expect(first.reload.person).not_to eq(second.reload.person)
      expect(unlinked.reload.person_id).to be_nil
      expect(report[:participants][:needs_review][:same_email_flagged]).to eq(1)
    end

    it "never uses a shared phone number to join people" do
      first = create(:participant, email: "one@example.com", phone: "+12025550143")
      second = create(:participant, email: "two@example.com", phone: "+12025550143")

      run

      expect(first.reload.person).not_to eq(second.reload.person)
      expect(PhoneNumber.where(number: "+12025550143").count).to eq(2)
    end

    it "skips a stored phone that is not a dialable number" do
      participant = create(:participant, email: "solo.attendee@example.com", phone: nil)
      participant.phone = "15555555"
      participant.save!(validate: false)

      report = run

      expect(participant.reload.person.phone_numbers).to be_empty
      expect(report[:phone_numbers][:skipped][:not_dialable]).to eq(1)
    end
  end

  describe "guardians" do
    it "creates one person per address when the names agree" do
      first = create(:guardian, email: "morgan.vale@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")
      second = store_legacy_email(
        create(:guardian, legal_first_name: "Morgan", legal_last_name: "Vale-Reed"), "Morgan.Vale@example.com"
      )
      alone = create(:guardian, email: "ash.reed@example.com")

      report = run

      expect(first.reload.person).to eq(second.reload.person)
      expect(alone.reload.person).not_to eq(first.person)
      expect(addresses_of(first.person)).to eq([ "morgan.vale@example.com" ])
      expect(report[:guardians][:mechanical]).to eq(same_email_names_agree: 2, single: 1)
    end

    it "leaves guardians sharing an inbox under different names unattached" do
      first = create(:guardian, email: "family@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")
      second = create(:guardian, email: "family@example.com", legal_first_name: "Ash", legal_last_name: "Vale")

      report = run

      expect([ first, second ].map { |row| row.reload.person_id }).to all(be_nil)
      expect(report[:guardians][:needs_review][:same_email_flagged]).to eq(2)
      expect(IdentityReview.find_by!(category: "guardian_duplicates").guardian_ids).to match_array([ first.id, second.id ])
    end

    it "keeps a guardian separate from an account or participant at the same address, and files the overlap" do
      user = create(:user, email: "morgan.vale@example.com", hack_club_account_id: "ident!morgan")
      attendee = create(:participant, user:, email: "morgan.vale@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")
      guardian = create(:guardian, email: "morgan.vale@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")

      report = run

      expect(guardian.reload.person).to be_present
      expect(guardian.person).not_to eq(user.reload.person)
      expect(guardian.person.email_addresses.sole).not_to be_verified
      expect(report[:guardians][:needs_review][:possible_same_person_kept_separate]).to eq(1)
      review = IdentityReview.find_by!(category: "guardian_overlap")
      expect(review).to have_attributes(guardian_ids: [ guardian.id ], user_ids: [ user.id ], participant_ids: [ attendee.id ])
    end

    it "does not file an overlap for a child using their parent's inbox" do
      create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale")
      guardian = create(:guardian, email: "family@example.com", legal_first_name: "Morgan", legal_last_name: "Vale")

      run

      expect(guardian.reload.person.participants).to be_empty
      expect(IdentityReview.where(category: "guardian_overlap")).to be_empty
      expect(EmailAddress.where(address: "family@example.com").count).to eq(2)
    end
  end

  describe "running it" do
    before do
      user = create(:user, email: "robin.vale@example.com", hack_club_account_id: "ident!robin", phone_number: "+12025550111")
      create(:participant, user:, email: "robin.vale@example.com")
      create(:participant, email: "family@example.com", legal_first_name: "Robin", legal_last_name: "Vale")
      create(:participant, email: "family@example.com", legal_first_name: "Alder", legal_last_name: "Vale")
      create(:participant, email: "solo.attendee@example.com")
      create(:guardian, email: "family@example.com")
      create(:guardian, email: "morgan.vale@example.com")
    end

    it "writes nothing on a dry run, and reports what an apply then does" do
      dry = nil
      expect { dry = run(apply: false) }.to not_change(Person, :count)
        .and not_change(EmailAddress, :count)
        .and not_change(PhoneNumber, :count)
        .and not_change(IdentityReview, :count)
        .and not_change { [ User, Participant, Guardian ].sum { |model| model.where.not(person_id: nil).count } }

      applied = run(apply: true)

      expect(dry).to eq(applied)
      expect(Person.count).to eq(applied[:people][:mechanical][:created])
      expect(EmailAddress.count).to eq(applied[:email_addresses][:mechanical].values.sum)
      expect(PhoneNumber.count).to eq(applied[:phone_numbers][:mechanical][:created])
      expect(IdentityReview.count).to eq(applied[:reviews][:needs_review][:groups_recorded])
    end

    it "changes nothing when run again" do
      run

      second = nil
      expect { second = run }.to not_change(Person, :count)
        .and not_change(EmailAddress, :count)
        .and not_change(PhoneNumber, :count)
        .and not_change(IdentityReview, :count)

      expect(second[:people][:mechanical][:created]).to eq(0)
      expect(second[:users][:skipped][:already_attached]).to eq(1)
      # Still unresolved, so still reported.
      expect(second[:participants][:needs_review][:same_email_flagged]).to eq(2)
    end

    it "leaves nobody without something pointing at them" do
      run

      expect(Person.unattached).to be_empty
    end

    it "picks up a row added after an earlier run without re-creating its person" do
      run
      person = Participant.find_by!(email: "solo.attendee@example.com").person
      later = create(:participant, email: "solo.attendee@example.com")

      expect { run }.not_to change(Person, :count)

      expect(later.reload.person).to eq(person)
    end

    it "does not touch updated_at or write versions on the rows it attaches" do
      participant = Participant.find_by!(email: "solo.attendee@example.com")
      participant.update_column(:updated_at, 3.days.ago)

      expect { run }.not_to change(PaperTrail::Version, :count)

      expect(participant.reload.updated_at).to be < 2.days.ago
    end

    it "reports counts and nothing else" do
      report = run(apply: false)

      leaves = report.values.flat_map(&:values).flat_map(&:values)
      expect(leaves).to all(be_an(Integer))
      expect(report.to_s).not_to match(/@|example|Vale|[0-9a-f]{8}-[0-9a-f]{4}/)
    end
  end
end
