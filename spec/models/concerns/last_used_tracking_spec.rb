require "rails_helper"

RSpec.describe LastUsedTracking do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:token) { MobileToken.generate_for(user) }

  it "stamps a credential the first time it is used" do
    expect(token.last_used_at).to be_nil

    token.touch_last_used!

    expect(token.reload.last_used_at).to be_within(5.seconds).of(Time.current)
  end

  it "leaves a recent stamp alone, without touching the database" do
    token.update_column(:last_used_at, 1.minute.ago)

    expect(token).not_to receive(:update_column)
    expect { token.touch_last_used! }.not_to change { token.reload.last_used_at }
  end

  it "stamps again once the interval has passed" do
    token.touch_last_used!

    travel_to(described_class::LAST_USED_TOUCH_INTERVAL.from_now + 1.second) do
      token.touch_last_used!
      expect(token.reload.last_used_at).to be_within(1.second).of(Time.current)
    end
  end

  # One implementation of "stamp at most every so often" (ThrottledStamp),
  # so a fix to it reaches the credentials and the guardian portal alike.
  it "shares its throttle with the guardian invite's last-used stamp" do
    expect([ MobileToken, GuardianParticipantEvent ]).to all(include(ThrottledStamp))
  end

  it "is how every API credential is stamped" do
    expect([ MobileToken, GlobalApiToken, EventApiToken, SeriesApiToken ]).to all(include(described_class))
  end

  describe "over the API", type: :request do
    it "writes on a credential's first request and not on the ones right after" do
      headers = { "Authorization" => "Bearer #{token.token}" }

      get api_v1_events_path, headers: headers
      expect(GetWriteDetector.drain.map(&:table)).to eq([ "mobile_tokens" ])

      get api_v1_events_path, headers: headers
      expect(response).to have_http_status(:ok)
      expect(GetWriteDetector.drain).to be_empty
    end
  end
end
