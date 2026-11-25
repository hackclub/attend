require "rails_helper"

RSpec.describe ParticipantEventPolicy do
  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }

  def staff(role, at: event)
    create(:user).tap { |user| create(:event_role_assignment, user: user, event: at, role: role) }
  end

  describe "#guardian_portal_link?" do
    before { Current.event = event }
    after { Current.reset }

    it "is open to every staff role that sees the admin participant page" do
      %w[event_admin ops limited safeguarding_lead].each do |role|
        expect(described_class.new(staff(role), participant_event).guardian_portal_link?).to be(true), role
      end
      expect(described_class.new(create(:user, global_role: "global_admin"), participant_event).guardian_portal_link?).to be(true)
    end

    it "is closed to staff of another event" do
      outsider = staff("event_admin", at: create(:event))

      expect(described_class.new(outsider, participant_event).guardian_portal_link?).to be(false)
    end

    # show? lets a participant see their own registration. That must not
    # stretch to minting their guardian's portal link.
    it "is closed to the participant themself, who can still see their own record" do
      owner = create(:user)
      participant_event.participant.update_columns(user_id: owner.id)
      policy = described_class.new(owner.reload, participant_event)

      expect(policy.show?).to be(true)
      expect(policy.guardian_portal_link?).to be(false)
    end
  end
end
