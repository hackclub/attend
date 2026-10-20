require "rails_helper"

RSpec.describe CountryCodes do
  it "has a code for every country Attend lists" do
    countries = ApplicationHelper::COUNTRIES - [ "---" ]

    expect(countries.map { |name| described_class.code_for(name) }).to all(match(/\A[A-Z]{2}\z/))
  end

  it "covers names Attend words differently from ISO" do
    expect(described_class.code_for("United Kingdom")).to eq("GB")
    expect(described_class.code_for("South Korea")).to eq("KR")
  end

  it "normalizes codes and names in any case to the stored name" do
    expect(described_class.normalize("us")).to eq("United States")
    expect(described_class.normalize(" united states ")).to eq("United States")
    expect(described_class.normalize("Narnia")).to be_nil
    expect(described_class.normalize("")).to be_nil
  end
end
