require "rails_helper"

RSpec.describe Bans::UcatSync do
  let(:client) { instance_double(Airtable::Client) }
  let(:records) { [] }

  def row(id:, email:, slack: nil, action: "Perma Ban", status: "resolved")
    { "id" => "rec#{id}", "fields" => { "ID" => id, "Subject Email" => email, "Subject Slack ID" => slack, "Action Taken" => action, "Status" => status }.compact }
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
      "Temp Ban" => false,
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
      expect(Ban.banned?("banned@example.com")).to be true
      expect(Ban.banned?("warned@example.com")).to be false
    end

    it "is idempotent" do
      sync
      expect { sync }.not_to change(Ban, :count)
      expect(sync.unchanged).to eq(1)
    end

    it "takes over an email from an expired or revoked ban so the person stays blocked" do
      lapsed = create(:ban, :expired, email: "banned@example.com")

      expect(sync.added).to eq(1)
      expect(Ban.banned?("banned@example.com")).to be true
      expect(Ban.ucat.sole.ban_emails.map(&:email)).to eq([ "banned@example.com" ])
      expect(lapsed.reload.ban_emails).to be_empty
    end

    it "skips an email already on an active manual ban" do
      create(:ban, email: "banned@example.com")

      expect(sync.skipped_existing).to eq(1)
      expect(Ban.ucat).to be_empty
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
