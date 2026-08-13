require "rails_helper"

RSpec.describe ParticipantMergeService do
  let(:event) { create(:event) }
  let(:primary) { create(:participant, email: "real@example.com") }
  let(:duplicate) { create(:participant, email: "typo@example.com") }

  let(:png) { file_fixture("headshot.png").binread }

  def merge!
    described_class.new(primary: primary, duplicate: duplicate).merge!
  end

  it "refuses to merge a participant into itself" do
    expect {
      described_class.new(primary: primary, duplicate: primary).merge!
    }.to raise_error(described_class::Error)
  end

  it "deletes the duplicate and keeps the primary" do
    primary
    duplicate
    expect { merge! }.to change(Participant, :count).by(-1)
    expect(Participant.exists?(primary.id)).to be(true)
    expect(Participant.exists?(duplicate.id)).to be(false)
  end

  it "keeps the primary's email" do
    merge!
    expect(primary.reload.email).to eq("real@example.com")
  end

  describe "event registrations" do
    it "moves registrations the primary doesn't have" do
      pe = create(:participant_event, participant: duplicate, event: event, status: :complete)

      merge!

      expect(pe.reload.participant_id).to eq(primary.id)
    end

    it "keeps the more progressed registration when both rows registered for the same event" do
      primary_pe = create(:participant_event, participant: primary, event: event, status: :in_progress)
      dup_pe = create(:participant_event, participant: duplicate, event: event, status: :complete)

      merge!

      expect(ParticipantEvent.exists?(primary_pe.id)).to be(false)
      expect(dup_pe.reload.participant_id).to eq(primary.id)
    end

    it "keeps the primary's registration on a status tie" do
      primary_pe = create(:participant_event, participant: primary, event: event, status: :complete)
      dup_pe = create(:participant_event, participant: duplicate, event: event, status: :complete)

      merge!

      expect(ParticipantEvent.exists?(dup_pe.id)).to be(false)
      expect(primary_pe.reload.participant_id).to eq(primary.id)
    end

    it "makes the merged person visible to the Slack channel sync (issue #323)" do
      create(:participant_event, participant: primary, event: event, status: :complete)
      duplicate.update!(slack_user_id: "U999")

      merge!

      invitable = event.participant_events.complete
        .joins(:participant)
        .where.not(participants: { slack_user_id: [ nil, "" ] })
      expect(invitable.map { |pe| pe.participant.slack_user_id }).to eq([ "U999" ])
    end
  end

  describe "profile backfill" do
    it "copies the duplicate's slack_user_id when the primary has none" do
      duplicate.update!(slack_user_id: "U12345")

      merge!

      expect(primary.reload.slack_user_id).to eq("U12345")
    end

    it "does not overwrite values the primary already has" do
      primary.update!(slack_user_id: "UPRIMARY", pronouns: "they/them")
      duplicate.update!(slack_user_id: "UDUP", pronouns: "she/her")

      merge!

      expect(primary.reload.slack_user_id).to eq("UPRIMARY")
      expect(primary.pronouns).to eq("they/them")
    end

    it "treats the Unknown placeholder as missing" do
      primary.update!(legal_first_name: "Unknown")
      duplicate.update!(legal_first_name: "Fiona")

      merge!

      expect(primary.reload.legal_first_name).to eq("Fiona")
    end
  end

  describe "sign-in account" do
    it "links the duplicate's user when the primary has none" do
      user = create(:user)
      duplicate.update!(user: user)

      merge!

      expect(primary.reload.user_id).to eq(user.id)
    end

    it "keeps the primary's user when both are linked" do
      primary_user = create(:user)
      primary.update!(user: primary_user)
      duplicate.update!(user: create(:user))

      merge!

      expect(primary.reload.user_id).to eq(primary_user.id)
    end
  end

  describe "headshot" do
    it "transfers the duplicate's headshot when the primary has none" do
      duplicate.headshot.attach(io: StringIO.new(png), filename: "headshot.jpg", content_type: "image/jpeg")

      merge!

      expect(primary.reload.headshot).to be_attached
    end

    it "keeps the primary's headshot when both have one" do
      primary.headshot.attach(io: StringIO.new(png), filename: "primary.jpg", content_type: "image/jpeg")
      duplicate.headshot.attach(io: StringIO.new(png), filename: "dup.jpg", content_type: "image/jpeg")
      primary_blob_id = primary.headshot.blob.id

      merge!

      expect(primary.reload.headshot.blob.id).to eq(primary_blob_id)
    end
  end

  describe "sibling group memberships" do
    it "moves memberships without duplicating shared groups" do
      other_sibling = create(:participant)
      shared_group = SiblingGroup.create!(label: "Shared")
      shared_group.sibling_memberships.create!(participant: primary)
      shared_group.sibling_memberships.create!(participant: duplicate)
      dup_only_group = SiblingGroup.create!(label: "Dup only")
      dup_only_group.sibling_memberships.create!(participant: duplicate)
      dup_only_group.sibling_memberships.create!(participant: other_sibling)

      merge!

      expect(primary.reload.sibling_groups).to contain_exactly(shared_group, dup_only_group)
      expect(shared_group.sibling_memberships.count).to eq(1)
    end
  end

  describe "#preview" do
    it "describes the merge without changing anything" do
      create(:participant_event, participant: duplicate, event: event, status: :complete)
      duplicate.update!(slack_user_id: "U777")

      preview = described_class.new(primary: primary, duplicate: duplicate).preview

      expect(preview.join("\n")).to include(event.name)
      expect(preview.join("\n")).to include("slack user")
      expect(Participant.exists?(duplicate.id)).to be(true)
      expect(primary.reload.slack_user_id).to be_nil
      expect(duplicate.reload.participant_events.count).to eq(1)
    end
  end

  describe "failure" do
    it "rolls everything back when the primary can't be saved" do
      pe = create(:participant_event, participant: duplicate, event: event, status: :complete)
      duplicate.update!(slack_user_id: "U555")
      primary.update_columns(email: "not-an-email")

      expect { merge! }.to raise_error(ActiveRecord::RecordInvalid)

      expect(Participant.exists?(duplicate.id)).to be(true)
      expect(pe.reload.participant_id).to eq(duplicate.id)
    end
  end
end
