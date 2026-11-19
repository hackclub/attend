require "rails_helper"

RSpec.describe ConsoleHelper, type: :helper do
  describe "#cs_form_errors" do
    it "renders nested autosave errors instead of raising" do
      travel = Travel.new
      travel.errors.add(:"travel_legs.departure_time_zone", "is needed: we don't know the time zone for that airport, so pick one")

      html = helper.cs_form_errors(travel)

      expect(html).to include("time zone for that airport")
    end

    it "still reads real attributes for length-based messages" do
      event = Event.new(name: "x" * 300)
      event.errors.add(:name, :too_long, count: 255)

      expect { helper.cs_form_errors(event) }.not_to raise_error
    end
  end
end
