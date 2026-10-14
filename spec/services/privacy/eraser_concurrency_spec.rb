require "rails_helper"

# The eraser's checks and deletes run on one connection while staff keep
# working on others. These commit for real, so a second connection can see
# them, and clean up after themselves.
RSpec.describe Privacy::Eraser, "under concurrent writes" do
  self.use_transactional_tests = false

  let!(:past_event) { create(:event, starts_at: 3.weeks.ago, ends_at: 2.weeks.ago, registration_open_at: 2.months.ago, registration_close_at: 1.month.ago) }
  let!(:user) { create(:user, email: "concurrent-attendee@example.com") }
  let!(:participant) { create(:participant, email: "concurrent-attendee@example.com", user:) }
  let!(:registration) { create(:participant_event, participant:, event: past_event, status: :complete) }
  let!(:reporter) { create(:user) }
  let(:subject_claims) { Privacy::Token::Subject.new(emails: [ "concurrent-attendee@example.com" ], slack_id: nil, identity_id: nil) }

  after do
    Incident.where(event: past_event).delete_all
    User.where(id: reporter.id).delete_all
    EventRoleAssignment.where(event: past_event).delete_all
    ParticipantEvent.where(event: past_event).destroy_all
    Participant.where(id: participant.id).destroy_all
    User.where(id: user.id).destroy_all
    past_event.destroy
  end

  # runs the write on its own connection once the eraser has passed its
  # checks, giving up after a short lock wait
  def write_after_checks(eraser, &write)
    outcome = nil
    allow(eraser).to receive(:check_review!).and_wrap_original do |original|
      original.call
      outcome = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            connection.execute("SET LOCAL lock_timeout = '300ms'")
            write.call
          end
          :committed
        rescue ActiveRecord::LockWaitTimeout
          :blocked
        end
      end.value
    end
    -> { outcome }
  end

  it "holds off a staff role granted after the staff check until the account is gone" do
    eraser = described_class.new(subject_claims)
    outcome = write_after_checks(eraser) { EventRoleAssignment.create!(user_id: user.id, event: past_event, role: "ops") }

    eraser.call(dry_run: false)

    expect(outcome.call).to eq(:blocked)
    expect(User.exists?(user.id)).to be(false)
    expect(EventRoleAssignment.where(event: past_event)).not_to exist
  end

  it "holds off an incident filed after the safeguarding check until the registration is gone" do
    eraser = described_class.new(subject_claims)
    outcome = write_after_checks(eraser) do
      Incident.create!(event: past_event, participant_event_id: registration.id, reported_by_user_id: reporter.id,
        category: :safeguarding, severity: :medium, summary: "fictional")
    end

    eraser.call(dry_run: false)

    expect(outcome.call).to eq(:blocked)
    expect(ParticipantEvent.exists?(registration.id)).to be(false)
    expect(Incident.where(event: past_event)).not_to exist
  end
end
