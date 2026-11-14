require "rails_helper"
require "rake"

RSpec.describe "backfill:remind_unsubmitted_registrations" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:remind_unsubmitted_registrations") }

  let(:event) { create(:event, starts_at: 1.day.from_now, ends_at: 2.days.from_now) }

  def adult_registration(evt, code_of_conduct_accepted_at: nil)
    create(:participant_event, event: evt, status: :in_progress, code_of_conduct_accepted_at: code_of_conduct_accepted_at).tap do |pe|
      pe.participant.update!(date_of_birth: 20.years.ago)
      create(:consent, :signed, participant_event: pe)
    end
  end

  let!(:stuck) { adult_registration(event) }
  let!(:unsigned) do
    create(:participant_event, event: event, status: :in_progress).tap do |pe|
      pe.participant.update!(date_of_birth: 20.years.ago)
    end
  end
  let!(:past) { adult_registration(create(:event, starts_at: 3.days.ago, ends_at: 2.days.ago)) }

  def run(apply:)
    previous = ENV["APPLY"]
    ENV["APPLY"] = apply ? "1" : nil
    expect { Rake::Task["backfill:remind_unsubmitted_registrations"].execute }.to output.to_stdout
  ensure
    ENV["APPLY"] = previous
  end

  it "only reports on a dry run" do
    expect { run(apply: false) }.not_to have_enqueued_mail(ParticipantMailer, :submission_needed)
    expect(stuck.reload.submission_reminder_sent_at).to be_nil
  end

  it "reminds only registrations waiting on submit for events that haven't ended" do
    expect { run(apply: true) }.to have_enqueued_mail(ParticipantMailer, :submission_needed).once

    expect(stuck.reload.submission_reminder_sent_at).to be_present
    expect(unsigned.reload.submission_reminder_sent_at).to be_nil
    expect(past.reload.submission_reminder_sent_at).to be_nil
  end
end
