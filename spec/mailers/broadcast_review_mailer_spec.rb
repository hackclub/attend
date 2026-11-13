require "rails_helper"

RSpec.describe BroadcastReviewMailer do
  let(:series) { create(:event_series) }
  let(:event) { create(:event, event_series: series) }
  let!(:admin_a) { User.create!(email: "admin-a@example.com", name: "Admin A", global_role: "global_admin") }
  let!(:admin_b) { User.create!(email: "admin-b@example.com", name: "Admin B", global_role: "global_admin") }
  let(:owner) { User.create!(email: "owner@example.com", name: "Owner") }
  let(:sender_owner) { User.create!(email: "sender-owner@example.com", name: "Sender Owner") }
  let(:organizer) { User.create!(email: "organizer@example.com", name: "Organizer") }
  let(:review) { instance_double(BroadcastReview, event: event, submitted_by_user_id: sender_owner.id) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BROADCAST_REVIEW_EMAIL").and_return(nil)
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:broadcast_review, :email).and_return(nil)
    create(:series_role_assignment, :owner, event_series: series, user: owner)
    create(:series_role_assignment, :owner, event_series: series, user: sender_owner)
    create(:series_role_assignment, event_series: series, user: organizer)
  end

  describe ".reviewer_emails" do
    it "goes to every global admin plus the series' other owners by default" do
      expect(described_class.reviewer_emails(review)).to contain_exactly(
        "admin-a@example.com", "admin-b@example.com", "owner@example.com"
      )
    end

    it "only emails the picked global admins once some are picked" do
      Setting.broadcast_review_recipient_user_ids = [ admin_b.id ]

      expect(described_class.reviewer_emails(review)).to contain_exactly("admin-b@example.com", "owner@example.com")
    end

    it "drops a picked user who is no longer a global admin" do
      Setting.broadcast_review_recipient_user_ids = [ admin_b.id, organizer.id ]
      admin_b.update!(global_role: :no_role)

      expect(described_class.reviewer_emails(review)).to contain_exactly(
        "admin-a@example.com", "owner@example.com"
      )
    end

    it "emails no series owners for an event outside a series" do
      event.update!(event_series: nil)

      expect(described_class.reviewer_emails(review)).to contain_exactly("admin-a@example.com", "admin-b@example.com")
    end
  end
end
