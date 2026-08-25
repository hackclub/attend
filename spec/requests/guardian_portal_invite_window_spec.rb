require "rails_helper"

RSpec.describe "guardian portal invite window", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:event) { create(:event) }
  let(:participant_event) { create(:participant_event, event: event) }
  let(:gpe) { create(:guardian_participant_event, participant_event: participant_event) }

  it "serves a link inside its window" do
    token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: 2.days.ago)

    get guardian_portal_path(token: token)

    expect(response).to have_http_status(:ok)
  end

  # The regression this whole change exists to prevent: a guardian who keeps
  # working must not be cut off seven days after the first email.
  it "keeps a guardian who is still using the portal signed in past the window" do
    token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: 6.days.ago)

    get guardian_portal_path(token: token)
    expect(response).to have_http_status(:ok)

    # Two weeks after the original send, but only days since that visit.
    travel 6.days do
      get guardian_portal_path(token: token)
      expect(response).to have_http_status(:ok)
    end

    travel 20.days do
      get guardian_portal_path(token: token)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "rejects a link nobody has touched for longer than the window" do
    token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: 8.days.ago)

    get guardian_portal_path(token: token)

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include(guardian_portal_center_path)
  end

  it "rejects a token whose send stamp was revoked" do
    token = gpe.generate_invite_token!
    gpe.update!(invite_token_sent_at: nil, invite_last_used_at: nil)

    get guardian_portal_path(token: token)

    expect(response).to have_http_status(:not_found)
  end
end
