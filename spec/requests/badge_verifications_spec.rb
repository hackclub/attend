require "rails_helper"

RSpec.describe "Badge verification", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:holder) { create(:user, name: "Example Holder", email: "holder-example@example.com") }
  let(:badge) { create(:training_badge, name: "Example Safety Badge") }
  let(:award) { create(:training_badge_award, user: holder, badge: badge) }

  describe "the public page" do
    it "shows a shared badge as valid, with no email and kept out of search" do
      award.share!
      get badge_verification_path(award.share_token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Example Safety Badge", "Example Holder", "Valid", "Hack Club")
      expect(response.body).not_to include("holder-example@example.com")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.body).to include('<meta name="robots" content="noindex, nofollow">')
    end

    it "says when a badge has been revoked or has expired" do
      award.share!
      award.revoke!(by: create(:user), reason: "Internal reason")
      get badge_verification_path(award.share_token)
      expect(response.body).to include("Revoked")
      expect(response.body).not_to include("Internal reason")

      expired = create(:training_badge_award, user: holder, badge: badge, awarded_at: 2.years.ago, expires_at: 1.year.ago)
      expired.share!
      get badge_verification_path(expired.share_token)
      expect(response.body).to include("Expired")
      expect(response.body).not_to include(">Valid<")
    end

    it "never falls back to the email address for a name" do
      holder.update_columns(name: nil, display_name: nil)
      award.share!
      get badge_verification_path(award.share_token)
      expect(response.body).to include("A Hack Club member")
      expect(response.body).not_to include("holder-example")
    end

    it "doesn't resolve an unshared badge, or a link that's been turned off" do
      award.share!
      token = award.share_token
      award.unshare!

      get badge_verification_path(token)
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Badge not found")
    end
  end

  describe "sharing, as the holder" do
    before { sign_in holder }

    it "turns a link on and off" do
      post share_training_award_path(award)
      expect(award.reload).to be_shared

      delete share_training_award_path(award)
      expect(award.reload).not_to be_shared
    end

    it "sends a current badge to LinkedIn's add-to-profile form, sharing it first" do
      post linkedin_training_award_path(award)

      expect(award.reload).to be_shared
      location = URI(response.location)
      expect(location.host).to eq("www.linkedin.com")
      query = Rack::Utils.parse_query(location.query)
      expect(query).to include(
        "startTask" => "CERTIFICATION_NAME",
        "name" => "Example Safety Badge",
        "organizationId" => "18031480",
        "issueYear" => award.awarded_at.year.to_s,
        "certUrl" => badge_verification_url(award.share_token)
      )
      expect(query["certId"]).to start_with("HC-")
    end

    it "won't start sharing a revoked badge, but keeps an existing link working" do
      award.revoke!(by: create(:user))
      post share_training_award_path(award)
      expect(award.reload).not_to be_shared

      live = create(:training_badge_award, user: holder, badge: badge)
      live.share!
      live.revoke!(by: create(:user))
      get badge_verification_path(live.share_token)
      expect(response.body).to include("Revoked")
    end

    it "won't add a revoked badge to LinkedIn" do
      award.revoke!(by: create(:user))
      post linkedin_training_award_path(award)
      expect(response).to redirect_to(training_award_path(award))
      expect(award.reload).not_to be_shared
    end
  end

  it "doesn't let anyone else change how a badge is shared, admins included" do
    sign_in create(:user, global_role: "global_admin")
    post share_training_award_path(award)
    expect(award.reload).not_to be_shared
  end

  it "lets admins upload badge artwork and shows it on the public page" do
    admin = create(:user, global_role: "global_admin")
    sign_in admin
    png = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1A\n" + "0" * 32), "image/png", true, original_filename: "badge.png")
    patch admin_training_badge_path(badge), params: { training_badge: { image: png } }
    expect(badge.reload.image).to be_attached

    award.share!
    get badge_verification_path(award.share_token)
    expect(response.body).to include('property="og:image"')
  end
end
