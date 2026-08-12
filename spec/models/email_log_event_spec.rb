require "rails_helper"

RSpec.describe EmailLogEvent, type: :model do
  describe "associations" do
    it "belongs to email_log" do
      assoc = EmailLogEvent.reflect_on_association(:email_log)
      expect(assoc.macro).to eq(:belongs_to)
    end
  end

  describe "validations" do
    it "requires event_type" do
      event = build(:email_log_event, event_type: nil)
      expect(event).not_to be_valid
      expect(event.errors[:event_type]).to include("can't be blank")
    end

    it "requires occurred_at" do
      event = build(:email_log_event, occurred_at: nil)
      expect(event).not_to be_valid
      expect(event.errors[:occurred_at]).to include("can't be blank")
    end
  end

  describe "enums" do
    it "defines event_type enum" do
      expect(EmailLogEvent.event_types).to eq({
        "sent" => "sent",
        "delivered" => "delivered",
        "opened" => "opened",
        "bounced" => "bounced",
        "link_clicked" => "link_clicked",
        "spam_complaint" => "spam_complaint"
      })
    end
  end

  describe "scopes" do
    describe ".chronological" do
      it "orders by occurred_at asc" do
        log = create(:email_log)
        old_event = create(:email_log_event, email_log: log, occurred_at: 2.hours.ago)
        new_event = create(:email_log_event, email_log: log, occurred_at: 1.hour.ago)

        expect(log.email_log_events.chronological).to eq([ old_event, new_event ])
      end
    end
  end

  describe "factory" do
    it "creates a valid email log event" do
      expect(build(:email_log_event)).to be_valid
    end
  end
end
