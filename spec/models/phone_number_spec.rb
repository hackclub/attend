require "rails_helper"

RSpec.describe PhoneNumber do
  let(:person) { create(:person) }

  it "stores the number in E.164" do
    number = create(:phone_number, person:, number: "(202) 555-0143")

    expect(number.reload.number).to eq("+12025550143")
  end

  it "rejects a number that cannot be dialled" do
    expect(build(:phone_number, person:, number: "15555555")).not_to be_valid
  end

  it "encrypts the number deterministically, so it can be found again" do
    number = create(:phone_number, person:, number: "+12025550143")
    stored = described_class.connection.select_value("SELECT number FROM phone_numbers WHERE id = #{described_class.connection.quote(number.id)}")

    expect(stored).not_to include("2025550143")
    expect(described_class.where(number: "+12025550143")).to contain_exactly(number)
  end

  it "holds a number once per person" do
    create(:phone_number, person:, number: "+12025550143")

    expect(build(:phone_number, person:, number: "202-555-0143")).not_to be_valid
  end

  it "never treats a number as belonging to one person" do
    create(:phone_number, person:, number: "+12025550143", verified_at: Time.current)
    shared = build(:phone_number, person: create(:person), number: "+12025550143", verified_at: Time.current)

    expect(shared.save).to be(true)
  end
end
