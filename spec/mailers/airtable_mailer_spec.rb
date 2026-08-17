require "rails_helper"

RSpec.describe AirtableMailer do
  describe "#sync_paused" do
    let(:recipient) { create(:user, email: "ops@hackclub.com", name: "Sam Rivers") }
    let(:event) { create(:event, name: "Horizons Polaris", slug: "horizons-polaris") }

    subject(:mail) do
      described_class.sync_paused(
        event: event,
        recipient: recipient,
        error_message: "HTTP 403: INVALID_PERMISSIONS: Invalid external table sync ID"
      )
    end

    before { event.pause_airtable_sync!("HTTP 403: INVALID_PERMISSIONS: Invalid external table sync ID") }

    it "goes to the person who last saved the config" do
      expect(mail.to).to eq([ "ops@hackclub.com" ])
      expect(mail.subject).to eq("Airtable sync paused for Horizons Polaris")
    end

    it "says the sync is paused and what Airtable complained about" do
      [ mail.html_part, mail.text_part ].each do |part|
        expect(part.body.to_s).to include("Invalid external table sync ID")
        expect(part.body.to_s.downcase).to include("paused")
      end
    end

    it "links to the event's integrations page so it can be fixed" do
      expect(mail.html_part.body.to_s).to include("/admin/horizons-polaris/integrations")
      expect(mail.text_part.body.to_s).to include("/admin/horizons-polaris/integrations")
    end

    it "greets the recipient by first name" do
      expect(mail.text_part.body.to_s).to include("Hi Sam,")
    end

    it "falls back to the email local part when the user has no name" do
      recipient.update!(name: nil, display_name: nil)

      expect(mail.text_part.body.to_s).to include("Hi ops,")
    end

    it "tells them Airtable is still showing the last good snapshot" do
      event.update_columns(airtable_synced_at: 2.hours.ago)

      expect(mail.text_part.body.to_s).to include("Last successful sync was")
    end

    it "says so when the integration never synced" do
      expect(mail.text_part.body.to_s).to include("never synced successfully")
    end

    it "logs the email against the event and the recipient" do
      expect { mail.deliver_now }.to change(EmailLog, :count).by(1)

      log = EmailLog.last
      expect(log.emailable).to eq(recipient)
      expect(log.event).to eq(event)
      expect(log.mailer_action).to eq("sync_paused")
    end
  end
end
