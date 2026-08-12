require "rails_helper"

RSpec.describe EmailLog, type: :model do
  describe "associations" do
    it "belongs to emailable (optional)" do
      assoc = EmailLog.reflect_on_association(:emailable)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:optional]).to be true
    end

    it "belongs to event (optional)" do
      assoc = EmailLog.reflect_on_association(:event)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:optional]).to be true
    end

    it "has many email_log_events with dependent destroy" do
      assoc = EmailLog.reflect_on_association(:email_log_events)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:dependent]).to eq(:destroy)
    end
  end

  describe "validations" do
    it "requires to_address" do
      log = build(:email_log, to_address: nil)
      expect(log).not_to be_valid
      expect(log.errors[:to_address]).to include("can't be blank")
    end

    it "requires from_address" do
      log = build(:email_log, from_address: nil)
      expect(log).not_to be_valid
      expect(log.errors[:from_address]).to include("can't be blank")
    end

    it "requires subject" do
      log = build(:email_log, subject: nil)
      expect(log).not_to be_valid
      expect(log.errors[:subject]).to include("can't be blank")
    end

    it "requires mailer_class" do
      log = build(:email_log, mailer_class: nil)
      expect(log).not_to be_valid
      expect(log.errors[:mailer_class]).to include("can't be blank")
    end

    it "requires mailer_action" do
      log = build(:email_log, mailer_action: nil)
      expect(log).not_to be_valid
      expect(log.errors[:mailer_action]).to include("can't be blank")
    end
  end

  describe "enums" do
    it "defines status enum" do
      expect(EmailLog.statuses).to eq({
        "sent" => "sent",
        "delivered" => "delivered",
        "opened" => "opened",
        "bounced" => "bounced",
        "failed" => "failed"
      })
    end
  end

  describe "scopes" do
    describe ".recent" do
      it "orders by created_at desc" do
        old_log = create(:email_log, created_at: 2.days.ago)
        new_log = create(:email_log, created_at: 1.day.ago)

        expect(EmailLog.recent).to eq([ new_log, old_log ])
      end
    end

    describe ".for_event" do
      it "filters by event" do
        event = create(:event)
        log_with_event = create(:email_log, event: event)
        create(:email_log, event: nil)

        expect(EmailLog.for_event(event)).to eq([ log_with_event ])
      end
    end
  end

  describe "factory" do
    it "creates a valid email log" do
      expect(build(:email_log)).to be_valid
    end

    it "creates delivered trait correctly" do
      log = create(:email_log, :delivered)
      expect(log.delivered?).to be true
      expect(log.delivered_at).to be_present
    end

    it "creates bounced trait correctly" do
      log = create(:email_log, :bounced)
      expect(log.bounced?).to be true
      expect(log.bounce_type).to be_present
    end
  end
end
