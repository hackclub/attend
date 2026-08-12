require "rails_helper"

RSpec.describe Participant, type: :model do
  describe "public profile" do
    it "generates a slug from the display name when enabled" do
      participant = create(:participant, legal_first_name: "Grace", legal_last_name: "Hopper")

      participant.update!(public_profile_enabled: true)

      expect(participant.public_profile_slug).to eq("grace-hopper")
    end

    it "prefers the preferred name for slug generation" do
      participant = create(:participant, preferred_name: "Gracie H")

      participant.update!(public_profile_enabled: true)

      expect(participant.public_profile_slug).to eq("gracie-h")
    end

    it "suffixes the slug on collision" do
      create(:participant, public_profile_enabled: true, legal_first_name: "Grace", legal_last_name: "Hopper")
      participant = create(:participant, legal_first_name: "Grace", legal_last_name: "Hopper")

      participant.update!(public_profile_enabled: true)

      expect(participant.public_profile_slug).to eq("grace-hopper-2")
    end

    it "normalizes a chosen slug" do
      participant = create(:participant, public_profile_slug: "  My-Slug ")

      expect(participant.public_profile_slug).to eq("my-slug")
    end

    it "rejects invalid slug formats" do
      participant = build(:participant, public_profile_slug: "bad slug!")

      expect(participant).not_to be_valid
      expect(participant.errors[:public_profile_slug]).to be_present
    end

    it "rejects bios over 500 characters" do
      participant = build(:participant, public_profile_bio: "a" * 501)

      expect(participant).not_to be_valid
    end

    it "keeps the profile disabled by default" do
      expect(create(:participant)).not_to be_public_profile_enabled
    end
  end

  describe "social handle normalization" do
    it "strips pasted URLs down to handles" do
      participant = create(:participant,
        public_profile_github: "https://github.com/leowilkin/",
        public_profile_twitter: "https://x.com/@leowilkin",
        public_profile_linkedin: "https://www.linkedin.com/in/leowilkin",
        public_profile_bluesky: "https://bsky.app/profile/leowilkin.com")

      expect(participant.public_profile_github).to eq("leowilkin")
      expect(participant.public_profile_twitter).to eq("leowilkin")
      expect(participant.public_profile_linkedin).to eq("leowilkin")
      expect(participant.public_profile_bluesky).to eq("leowilkin.com")
    end

    it "strips @ prefixes from bare handles" do
      participant = create(:participant, public_profile_twitter: "@leowilkin")

      expect(participant.public_profile_twitter).to eq("leowilkin")
    end

    it "converts mastodon handles to profile URLs" do
      participant = create(:participant, public_profile_mastodon: "@leo@hachyderm.io")

      expect(participant.public_profile_mastodon).to eq("https://hachyderm.io/@leo")
    end

    it "rejects non-https mastodon values" do
      participant = build(:participant, public_profile_mastodon: "javascript:alert(1)")

      expect(participant).not_to be_valid
    end

    it "prefixes bare website domains with https" do
      participant = create(:participant, public_profile_website: "leowilkin.com")

      expect(participant.public_profile_website).to eq("https://leowilkin.com")
    end

    it "rejects javascript: website values" do
      participant = build(:participant, public_profile_website: "javascript:alert(1)")

      expect(participant).not_to be_valid
    end
  end

  describe "#hca_verified?" do
    it "is true only when the linked user is HCA-verified" do
      expect(create(:participant)).not_to be_hca_verified

      user = create(:user, oidc_claims: { "verification_status" => "verified" })
      expect(create(:participant, user: user)).to be_hca_verified

      unverified_user = create(:user, oidc_claims: { "verification_status" => "pending" })
      expect(create(:participant, user: unverified_user)).not_to be_hca_verified
    end
  end

  describe "#public_profile_display_photo" do
    it "prefers the uploaded profile photo over the headshot" do
      png = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      participant = create(:participant)
      expect(participant.public_profile_display_photo).to be_nil

      participant.headshot.attach(io: StringIO.new(png), filename: "headshot.png", content_type: "image/png")
      expect(participant.public_profile_display_photo).to eq(participant.headshot)

      participant.public_profile_photo.attach(io: StringIO.new(png), filename: "profile.png", content_type: "image/png")
      expect(participant.public_profile_display_photo).to eq(participant.public_profile_photo)
    end
  end

  describe "#public_profile_participant_events" do
    let(:participant) { create(:participant) }

    def past_event
      create(:event, starts_at: 3.months.ago, ends_at: 3.months.ago + 2.days,
                     registration_close_at: 4.months.ago)
    end

    it "includes checked-in complete registrations for events that have ended" do
      participant_event = create(:participant_event, :checked_in, participant: participant,
                                                                  event: past_event, status: :complete)

      expect(participant.public_profile_participant_events).to contain_exactly(participant_event)
    end

    it "excludes registrations without a check-in" do
      create(:participant_event, participant: participant, event: past_event, status: :complete)

      expect(participant.public_profile_participant_events).to be_empty
    end

    it "excludes upcoming events, incomplete registrations, and hidden events" do
      create(:participant_event, :checked_in, participant: participant, status: :complete) # future event
      create(:participant_event, :checked_in, participant: participant, event: past_event, status: :withdrawn)
      create(:participant_event, :checked_in, participant: participant, event: past_event, status: :complete,
                                              hidden_from_public_profile: true)

      expect(participant.public_profile_participant_events).to be_empty
    end
  end
end
