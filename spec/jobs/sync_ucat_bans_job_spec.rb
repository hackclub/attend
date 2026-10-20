require "rails_helper"

RSpec.describe SyncUcatBansJob do
  include ActiveJob::TestHelper

  let(:sync) { instance_double(Bans::UcatSync, call: Bans::UcatSync::Result.new) }
  let(:upcoming) { create(:event, name: "Upcoming Hackathon") }
  let(:past) { create(:event, name: "Past Hackathon", starts_at: 2.weeks.ago, ends_at: 1.week.ago) }
  let(:banned) { create(:participant, legal_first_name: "Robin", legal_last_name: "Testerton", email: "banned@example.com") }

  before do
    allow(Bans::UcatSync).to receive(:new).and_return(sync)
    stub_const("ENV", ENV.to_h.merge("BAN_ALERT_RECIPIENTS" => "alerts@example.com, second@example.com"))
  end

  # Ban.banned? blocks new enrollments, so these people got in before the ban.
  def ban!(email = "banned@example.com")
    create(:ban, email: email)
  end

  it "emails a summary of banned people enrolled in events that haven't ended" do
    create(:participant_event, participant: banned, event: upcoming)
    create(:participant_event, participant: banned, event: past)
    create(:participant_event, event: upcoming) # not banned
    ban!

    perform_enqueued_jobs { described_class.perform_now }

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(%w[alerts@example.com second@example.com])
    expect(mail.subject).to eq("1 banned person on upcoming events")
    body = mail.text_part.body.to_s
    expect(body).to include("Robin Testerton", "Upcoming Hackathon")
    expect(body).not_to include("Past Hackathon")
  end

  it "matches by Slack ID when the email differs" do
    other = create(:participant, legal_first_name: "Sam", legal_last_name: "Slackman", email: "different@example.com", slack_user_id: "u0banned1")
    create(:participant_event, participant: other, event: upcoming)
    Ban.create!(ban_slack_ids: [ BanSlackId.new(slack_id: "U0BANNED1") ])

    perform_enqueued_jobs { described_class.perform_now }

    expect(ActionMailer::Base.deliveries.last.text_part.body.to_s).to include("Sam Slackman")
  end

  it "ignores withdrawn enrollments and revoked bans" do
    create(:participant_event, participant: banned, event: upcoming, status: :withdrawn)
    other = create(:participant, email: "lifted@example.com")
    create(:participant_event, participant: other, event: upcoming)
    ban!
    ban!("lifted@example.com").revoke!

    expect { described_class.perform_now }.not_to have_enqueued_mail(BanMailer, :upcoming_enrollments)
  end

  it "still sends the alert when the sync refuses to run" do
    allow(sync).to receive(:call).and_raise(Bans::UcatSync::SafetyLimitExceeded, "nope")
    create(:participant_event, participant: banned, event: upcoming)
    ban!

    expect { described_class.perform_now }
      .to raise_error(Bans::UcatSync::SafetyLimitExceeded)
      .and have_enqueued_mail(BanMailer, :upcoming_enrollments)
  end
end
