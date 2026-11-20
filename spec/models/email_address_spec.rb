require "rails_helper"

RSpec.describe EmailAddress do
  let(:person) { create(:person) }
  let(:other_person) { create(:person) }

  it "stores the address stripped and downcased" do
    address = create(:email_address, person:, address: "  Robin.Vale@Example.COM ")

    expect(address.reload.address).to eq("robin.vale@example.com")
  end

  it "rejects something that is not an address" do
    expect(build(:email_address, person:, address: "not an address")).not_to be_valid
  end

  it "holds an address once per person, whatever the case" do
    create(:email_address, person:, address: "robin.vale@example.com")

    expect(build(:email_address, person:, address: "Robin.Vale@example.com")).not_to be_valid
  end

  describe "sharing an address" do
    it "lets several people hold the same unverified address" do
      create(:email_address, person:, address: "family@example.com")

      expect(create(:email_address, person: other_person, address: "family@example.com")).to be_persisted
    end

    it "lets one person verify an address others hold unverified" do
      create(:email_address, person:, address: "family@example.com")

      expect(create(:email_address, :verified, person: other_person, address: "family@example.com")).to be_persisted
    end

    it "refuses a second person verifying the same address" do
      create(:email_address, :verified, person:, address: "family@example.com")
      second = build(:email_address, :verified, person: other_person, address: "Family@example.com")

      expect(second).not_to be_valid
      expect(second.errors[:address]).to include("is already verified for another person")
    end

    it "is enforced by the database when validations are skipped" do
      create(:email_address, :verified, person:, address: "family@example.com")
      second = build(:email_address, :verified, person: other_person, address: "family@example.com")

      expect { second.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses verifying an address someone else has verified" do
      create(:email_address, :verified, person:, address: "family@example.com")
      unverified = create(:email_address, person: other_person, address: "family@example.com")

      expect(unverified.update(verified_at: Time.current)).to be(false)
    end
  end

  describe "primary" do
    it "allows one primary address per person" do
      create(:email_address, person:, primary: true)

      expect(build(:email_address, person:, primary: true)).not_to be_valid
      expect(create(:email_address, person: other_person, primary: true)).to be_persisted
    end
  end

  it "goes when its person does" do
    create(:email_address, person:)

    expect { person.destroy! }.to change(described_class, :count).by(-1)
  end
end
