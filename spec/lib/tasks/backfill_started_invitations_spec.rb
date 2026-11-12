require "rails_helper"
require "rake"

RSpec.describe "backfill:started_invitations" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:started_invitations") }

  let(:event) { create(:event) }
  let!(:stale) { create(:invitation, event: event, email: "fern.started@example.com", sent_at: 2.days.ago) }
  let!(:waiting) { create(:invitation, event: event, email: "ash.waiting@example.com", sent_at: 2.days.ago) }

  before do
    create(:participant_event, event: event, status: :complete,
      participant: create(:participant, email: "fern.started@example.com"))
    create(:participant_event, event: event, status: :invited,
      participant: create(:participant, email: "ash.waiting@example.com"))
    # As it sat before ParticipantEvent#accept_invitations existed.
    stale.update_column(:accepted_at, nil)
  end

  def run(apply:)
    previous = ENV["APPLY"]
    ENV["APPLY"] = apply ? "1" : nil
    expect { Rake::Task["backfill:started_invitations"].execute }.to output.to_stdout
  ensure
    ENV["APPLY"] = previous
  end

  it "only reports on a dry run" do
    run(apply: false)

    expect(stale.reload).not_to be_accepted
  end

  it "accepts invitations for started registrations and leaves invited ones pending" do
    run(apply: true)

    expect(stale.reload).to be_accepted
    expect(waiting.reload).not_to be_accepted
  end
end
