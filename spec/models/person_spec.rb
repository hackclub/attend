require "rails_helper"

RSpec.describe Person do
  let(:person) { create(:person) }

  it "sits above a user, participants and guardians without owning them" do
    user = create(:user, person:)
    participant = create(:participant, person:)
    guardian = create(:guardian, person:)

    expect(person.users).to contain_exactly(user)
    expect(person.participants).to contain_exactly(participant)
    expect(person.guardians).to contain_exactly(guardian)

    person.destroy!

    expect([ user, participant, guardian ].map { |record| record.reload.person_id }).to all(be_nil)
  end

  it "is optional on every row it sits above" do
    expect(create(:user).person).to be_nil
    expect(create(:participant).person).to be_nil
    expect(create(:guardian).person).to be_nil
  end

  it "finds people nothing points at any more" do
    attached = create(:person)
    create(:guardian, person: attached)

    expect(described_class.unattached).to contain_exactly(person)
  end

  it "knows its primary address" do
    create(:email_address, person:)
    primary = create(:email_address, person:, primary: true)

    expect(person.primary_email_address).to eq(primary)
  end
end
