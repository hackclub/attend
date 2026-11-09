require "rails_helper"
require "rake"

RSpec.describe "backfill:invitation_emails" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:invitation_emails") }

  let(:event) { create(:event) }
  let(:participant) { create(:participant, email: "wren.old@example.com") }
  let!(:left_behind) { create(:invitation, event: event, email: "wren.old@example.com", sent_at: nil) }
  let!(:untraced) { create(:invitation, event: event, email: "nobody-ever@example.com", sent_at: nil) }

  before do
    # The change paper_trail recorded, then the invitation put back where it
    # sat before invitations followed email changes.
    participant.update!(email: "wren.new@example.com")
    left_behind.update_column(:email, "wren.old@example.com")
  end

  def run(apply:)
    previous = ENV["APPLY"]
    ENV["APPLY"] = apply ? "1" : nil
    expect { Rake::Task["backfill:invitation_emails"].execute }.to output.to_stdout
  ensure
    ENV["APPLY"] = previous
  end

  it "only reports on a dry run" do
    run(apply: false)

    expect(left_behind.reload.email).to eq("wren.old@example.com")
  end

  it "moves invitations off an address a participant left, and nothing else" do
    run(apply: true)

    expect(left_behind.reload.email).to eq("wren.new@example.com")
    expect(untraced.reload.email).to eq("nobody-ever@example.com")
  end
end
