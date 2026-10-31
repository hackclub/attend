require "rails_helper"

RSpec.describe Exports::Filter do
  # Los Angeles: UTC-7 in July.
  let(:los_angeles) { ActiveSupport::TimeZone["Pacific Time (US & Canada)"] }
  let(:participant_event) { create(:participant_event) }

  def filter(field_key, operator, value, time_zone: los_angeles)
    described_class.new(field: Exports::FieldRegistry.fetch(field_key), operator: operator, value: value, time_zone: time_zone)
  end

  describe "a datetime field" do
    # July 11, 20:00 in Los Angeles, already July 12 in UTC.
    before { participant_event.update_columns(onboarding_completed_at: Time.utc(2030, 7, 12, 3, 0)) }

    def matches?(operator, value, **options)
      filter("participant_event.onboarding_completed_at", operator, value, **options).matches?(participant_event)
    end

    it "reads a typed time on the event's clock" do
      expect(matches?("before", "2030-07-11T20:30")).to be(true)
      expect(matches?("after", "2030-07-11T20:30")).to be(false)
      expect(matches?("after", "2030-07-11T19:30")).to be(true)
    end

    it "keeps a value that names its own offset" do
      expect(matches?("before", "2030-07-12T03:30:00Z")).to be(true)
      expect(matches?("after", "2030-07-12T02:30:00Z")).to be(true)
    end

    it "compares a bare date with the event's calendar day" do
      expect(matches?("on", "2030-07-11")).to be(true)
      expect(matches?("on", "2030-07-12")).to be(false)
      expect(matches?("before", "2030-07-12")).to be(true)
      expect(matches?("after", "2030-07-11")).to be(false)
      expect(matches?("after", "2030-07-10")).to be(true)
    end

    it "uses UTC when no zone is given" do
      expect(matches?("on", "2030-07-12", time_zone: nil)).to be(true)
      expect(matches?("before", "2030-07-11T20:30", time_zone: nil)).to be(false)
    end
  end

  describe "a date field" do
    before { participant_event.create_accommodation!(check_in_date: Date.new(2030, 7, 10)) }

    def matches?(operator, value)
      filter("accommodation.check_in_date", operator, value).matches?(participant_event)
    end

    # A plain date is a calendar day wherever the event is.
    it "compares calendar days, whatever the event's zone" do
      expect(matches?("on", "2030-07-10")).to be(true)
      expect(matches?("before", "2030-07-10")).to be(false)
      expect(matches?("before", "2030-07-11")).to be(true)
      expect(matches?("after", "2030-07-10")).to be(false)
      expect(matches?("after", "2030-07-09")).to be(true)
    end
  end

  it "builds with the zone it's given and leaves it out of the saved form" do
    built = described_class.build({ "field" => "participant_event.onboarding_completed_at", "operator" => "on", "value" => "2030-07-11" },
                                  time_zone: los_angeles)

    expect(built.time_zone).to eq(los_angeles)
    expect(built.to_h).to eq("field" => "participant_event.onboarding_completed_at", "operator" => "on", "value" => "2030-07-11")
  end
end
