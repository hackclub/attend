require "rails_helper"

RSpec.describe AuditViewJob do
  include ActiveJob::TestHelper

  let(:actor) { create(:user) }
  let(:event) { create(:event) }
  let(:record) { create(:participant_event, event: event) }

  it "writes the view entry with the time of the view, not of the job" do
    viewed_at = 10.minutes.ago.change(usec: 0)

    described_class.perform_now(
      record_type: "ParticipantEvent", record_id: record.id, actor_user_id: actor.id,
      event_id: event.id, metadata: { "what" => "example" }, viewed_at: viewed_at
    )

    expect(AuditLog.sole).to have_attributes(
      action: "view", record: record, actor: actor, event: event, metadata: { "what" => "example" }, created_at: viewed_at
    )
  end

  it "is queued by AuditLog.log_view_later, which doesn't write itself" do
    expect {
      AuditLog.log_view_later(record: record, actor: actor, event: event, metadata: { what: "example" })
    }.to have_enqueued_job(described_class).and(not_change(AuditLog, :count))

    perform_enqueued_jobs

    expect(AuditLog.sole).to have_attributes(action: "view", record_id: record.id, actor_user_id: actor.id, event_id: event.id)
    expect(AuditLog.sole.created_at).to be_within(5.seconds).of(Time.current)
  end

  # The page was served before the job ran, so a failed write can't fail the
  # view any more. It has to be tried again instead.
  it "tries again when the write fails, and records the view once with its original time" do
    viewed_at = 10.minutes.ago.change(usec: 0)
    args = { record_type: "ParticipantEvent", record_id: record.id, actor_user_id: actor.id, viewed_at: viewed_at }
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { described_class.perform_now(**args) }.to have_enqueued_job(described_class).and(not_change(AuditLog, :count))

    allow(AuditLog).to receive(:create!).and_call_original
    perform_enqueued_jobs

    expect(AuditLog.where(action: "view").sole).to have_attributes(record_id: record.id, created_at: viewed_at)
  end

  it "still records the view when the record is gone by the time it runs" do
    AuditLog.log_view_later(record: record, actor: actor, metadata: { what: "example" })
    record_id = record.id
    record.destroy!

    perform_enqueued_jobs

    expect(AuditLog.where(action: "view", record_type: "ParticipantEvent", record_id: record_id)).to exist
  end
end
