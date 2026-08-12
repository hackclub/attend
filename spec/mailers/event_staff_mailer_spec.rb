require "rails_helper"

RSpec.describe EventStaffMailer, type: :mailer do
  describe "#added_to_event" do
    let(:event) { create(:event, name: "Test Summit") }
    let(:staff_user) { create(:user, email: "newstaff@example.com", name: "New Staff") }
    let(:added_by) { create(:user, email: "boss@example.com", name: "The Boss") }
    let(:assignment) do
      event.event_role_assignments.create!(user: staff_user, role: "event_admin")
    end

    it "tells the new staff member about their role and links to the event" do
      mail = described_class.added_to_event(assignment: assignment, added_by: added_by)

      expect(mail.to).to eq([ "newstaff@example.com" ])
      expect(mail.reply_to).to eq([ "boss@example.com" ])
      expect(mail.subject).to eq("You've been added to Test Summit on Attend")
      expect(mail.body.encoded).to include("The Boss")
      expect(mail.body.encoded).to include("Event Admin")
      expect(mail.body.encoded).to include("Manage staff and their roles")
      expect(mail.body.encoded).to include("/admin/#{event.slug}")
    end

    it "lists what a limited role cannot do" do
      assignment.update!(role: "read_only")

      mail = described_class.added_to_event(assignment: assignment, added_by: added_by)

      expect(mail.body.encoded).to include("Read Only")
      expect(mail.body.encoded).to include("Make any changes")
    end

    it "falls back to the shared inbox when there is no adder" do
      mail = described_class.added_to_event(assignment: assignment)

      expect(mail.reply_to).to eq([ "attend@hackclub.com" ])
      expect(mail.body.encoded).to include("been added to")
      expect(mail.body.encoded).not_to include("The Boss")
    end
  end
end
