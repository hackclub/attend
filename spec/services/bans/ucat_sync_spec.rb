require "rails_helper"

RSpec.describe Bans::UcatSync do
  let(:client) { instance_double(Airtable::Client) }
  let(:records) { [] }

  def row(id:, email:, slack: nil, action: "Perma Ban", status: "resolved", until_at: nil)
    { "id" => "rec#{id}", "fields" => { "ID" => id, "Subject Email" => email, "Subject Slack ID" => slack, "Action Taken" => action, "Action Until" => until_at&.iso8601, "Status" => status }.compact }
  end

  def sync(force: false)
    described_class.new(client: client, force: force).call
  end

  before do
    allow(client).to receive(:list_records).and_return("records" => records)
  end

  describe ".qualifies?" do
    {
      "Perma Ban" => true,
      "Perma Ban, indefinite ban + 1wk shush on appeal" => true,
      "Indef Ban, Must verify identity" => true,
      "Warning, Permanent banned alt" => true,
      "ive perma banned with appeal" => true,
      "ban" => true,
      "Warning, Ban" => true,
      "Temp Ban" => false, # no Action Until
      "Channel Ban" => false,
      "Banned for 3 months" => false,
      "Warning, any further incidents will lead to a permanent ban" => false,
      "Deleted screenshot, discussing perma/temp ban" => false,
      "shush 1 wk + permanent channel ban" => false
    }.each do |action, expected|
      it "is #{expected} for #{action.inspect}" do
        expect(described_class.qualifies?("Action Taken" => action, "Status" => "resolved")).to be expected
      end
    end

    it "ignores cases marked removed" do
      expect(described_class.qualifies?("Action Taken" => "Perma Ban", "Status" => "removed")).to be false
    end

    it "counts a temp ban only when the case says when it ends" do
      expect(described_class.qualifies?("Action Taken" => "Temp Ban", "Action Until" => "2030-01-01T00:00:00.000Z", "Status" => "resolved")).to be true
      expect(described_class.qualifies?("Action Taken" => "Temporary ban, 2 weeks", "Action Until" => "2030-01-01T00:00:00.000Z", "Status" => "resolved")).to be true
      expect(described_class.qualifies?("Action Taken" => "Temp Ban", "Action Until" => "not a date", "Status" => "resolved")).to be false
    end
  end

  describe "temp bans" do
    let(:until_at) { 2.weeks.from_now.change(usec: 0) }
    let(:records) { [ row(id: "T1", email: "temp@example.com", action: "Temp Ban", until_at: until_at) ] }

    it "mirrors the case's end date as the ban expiry" do
      expect(sync.added).to eq(1)
      ban = Ban.ucat.sole
      expect(ban.expires_at).to eq(until_at)
      expect(ban).to be_active
    end

    it "lets the ban expire rather than revoking it once the date has passed" do
      sync
      records[0] = row(id: "T1", email: "temp@example.com", action: "Temp Ban", until_at: 1.day.ago.change(usec: 0))

      result = sync
      expect(result.revoked).to eq(0)
      ban = Ban.ucat.sole
      expect(ban).not_to be_revoked
      expect(ban.status).to eq("Expired")
      expect(Ban.banned?("temp@example.com")).to be false
    end

    it "becomes indefinite when the same person also has a perma ban" do
      records << row(id: "T2", email: "temp@example.com", action: "Perma Ban")
      sync
      expect(Ban.ucat.sole.expires_at).to be_nil
    end

    it "takes the latest end date across several temp bans" do
      later = 4.weeks.from_now.change(usec: 0)
      records << row(id: "T2", email: "temp@example.com", action: "Temp Ban", until_at: later)
      sync
      expect(Ban.ucat.sole.expires_at).to eq(later)
    end
  end

  it "follows pagination" do
    allow(client).to receive(:list_records).with(anything, hash_including(offset: nil))
      .and_return("records" => [ row(id: "1", email: "first@example.com") ], "offset" => "next")
    allow(client).to receive(:list_records).with(anything, hash_including(offset: "next"))
      .and_return("records" => [ row(id: "2", email: "second@example.com") ])

    expect(sync.added).to eq(2)
    expect(Ban.banned?("second@example.com")).to be true
  end

  context "with qualifying cases" do
    let(:records) do
      [
        row(id: "A1", email: " Banned@Example.com "),
        row(id: "A2", email: "banned@example.com", action: "Indef Ban"),
        row(id: "A3", email: "warned@example.com", action: "Warning"),
        row(id: "A4", email: nil)
      ]
    end

    it "creates one ucat ban per email and counts cases it cannot enforce" do
      result = sync

      expect(result.added).to eq(1)
      expect(result.cases_without_identity).to eq(1)
      ban = Ban.ucat.sole
      expect(ban.external_key).to eq("banned@example.com")
      expect(ban.reason).to include("A1, A2")
      expect(ban.ucat_cases).to eq([ { "id" => "A1", "record_id" => "recA1" }, { "id" => "A2", "record_id" => "recA2" } ])
      expect(ban.ucat_case_links.map(&:last)).to all(start_with("https://airtable.com/#{described_class::BASE_ID}/#{described_class::TABLE_ID}/rec"))
      expect(Ban.banned?("banned@example.com")).to be true
      expect(Ban.banned?("warned@example.com")).to be false
    end

    it "fills case links on a ban synced before they were stored" do
      legacy = create(:ban, source: :ucat, external_key: "banned@example.com", email: "banned@example.com", reason: "UCAT ban (cases A1, A2)")
      expect(legacy.ucat_cases).to eq([])

      expect(sync.unchanged).to eq(1)
      expect(legacy.reload.ucat_cases.map { _1["record_id"] }).to eq(%w[recA1 recA2])
    end

    it "is idempotent" do
      sync
      expect { sync }.not_to change(Ban, :count)
      expect(sync.unchanged).to eq(1)
    end

    [ :expired, :revoked_by_admin, :active ].each do |state|
      it "bans the person alongside a #{state} manual ban on the same email, leaving that ban untouched" do
        admin = create(:user)
        manual = create(:ban, email: "banned@example.com", expires_at: (1.day.ago if state == :expired))
        manual.revoke!(by: admin) if state == :revoked_by_admin

        expect(sync.added).to eq(1)
        expect(Ban.banned?("banned@example.com")).to be true
        expect(manual.reload.ban_emails.map(&:email)).to eq([ "banned@example.com" ])
        expect(manual.revoked_by).to eq(state == :revoked_by_admin ? admin : nil)
      end
    end

    it "still stops an admin adding a manual ban for an email that's already listed" do
      sync
      duplicate = build(:ban, email: "banned@example.com")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors.full_messages.join).to include("already on a ban list")
    end
  end

  context "with Slack IDs" do
    let(:records) do
      [
        row(id: "S1", email: nil, slack: "u0slackonly"),
        row(id: "S2", email: "linked@example.com", slack: "U0LINKED1"),
        row(id: "S3", email: nil, slack: "U0LINKED1", action: "ban")
      ]
    end

    it "bans Slack-only cases and groups cases that share an identifier into one person" do
      expect(sync.added).to eq(2)

      expect(Ban.banned?(nil, slack_ids: [ "U0SLACKONLY" ])).to be true
      linked = Ban.ucat.find_by!(external_key: "linked@example.com")
      expect(linked.ban_slack_ids.map(&:slack_id)).to eq([ "U0LINKED1" ])
      expect(linked.reason).to include("S2, S3")
    end

    it "keeps the same ban when a Slack-only person later gains an email" do
      sync
      slack_only = Ban.ucat.find_by!(external_key: "slack:U0SLACKONLY")

      records[0] = row(id: "S1", email: "found@example.com", slack: "U0SLACKONLY")
      expect { sync }.not_to change(Ban, :count)
      expect(slack_only.reload.external_key).to eq("found@example.com")
      expect(Ban.banned?("found@example.com")).to be true
    end
  end

  describe "removal" do
    let!(:kept) { Array.new(8) { |i| create(:ban, source: :ucat, external_key: "kept#{i}@example.com", email: "kept#{i}@example.com") } }
    let!(:lifted) { create(:ban, source: :ucat, external_key: "lifted@example.com", email: "lifted@example.com") }
    let(:records) { kept.map { |ban| row(id: ban.external_key, email: ban.external_key) } }

    it "revokes a ban whose case no longer qualifies, then reinstates it if it returns" do
      expect(sync.revoked).to eq(1)
      expect(lifted.reload).to be_revoked
      expect(lifted.revoked_by).to be_nil

      records << row(id: "L", email: "lifted@example.com")
      expect(sync.reinstated).to eq(1)
      expect(lifted.reload).to be_active
    end

    it "leaves a ban an admin revoked by hand alone" do
      admin = create(:user)
      kept.first.revoke!(by: admin)

      expect(sync.reinstated).to eq(0)
      expect(kept.first.reload.revoked_by).to eq(admin)
    end

    it "never touches manual bans" do
      manual = create(:ban, email: "manual@example.com")
      sync
      expect(manual.reload).to be_active
    end

    context "when the fetch looks broken" do
      let(:records) { [] }

      it "refuses to revoke everything without force" do
        expect { sync }.to raise_error(described_class::SafetyLimitExceeded)
        expect(Ban.ucat.active.count).to eq(9)
      end

      it "revokes everything when forced" do
        expect(sync(force: true).revoked).to eq(9)
      end
    end
  end
end
