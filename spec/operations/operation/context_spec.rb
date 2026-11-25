require "rails_helper"

RSpec.describe Operation::Context do
  let(:event) { create(:event) }
  let(:other_event) { create(:event) }
  # Limited where they're working, ops somewhere else.
  let(:user) do
    create(:user).tap do |user|
      EventRoleAssignment.create!(user: user, event: event, role: "limited")
      EventRoleAssignment.create!(user: user, event: other_event, role: "ops")
    end
  end

  describe "#can_view_pii?" do
    it "judges an event-scoped context against its event" do
      expect(described_class.new(surface: :html, user: user, event: event).can_view_pii?).to be(false)
      expect(described_class.new(surface: :html, user: user, event: other_event).can_view_pii?).to be(true)
    end

    it "judges an any-scoped context against every event the user has a role on" do
      expect(described_class.new(surface: :mcp, user: user, event: event, pii_scope: :any).can_view_pii?).to be(true)
    end

    it "fails closed when an event-scoped context has no event, rather than widening to any event" do
      expect(described_class.new(surface: :html, user: user, event: nil).can_view_pii?).to be(false)
    end

    it "still lets a global admin through with no event" do
      admin = create(:user, global_role: "global_admin")

      expect(described_class.new(surface: :html, user: admin, event: nil).can_view_pii?).to be(true)
    end

    it "is false without a user" do
      expect(described_class.new(surface: :api, user: nil, event: event, api_key: true).can_view_pii?).to be(false)
    end
  end
end
