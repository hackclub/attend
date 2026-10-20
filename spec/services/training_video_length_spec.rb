require "rails_helper"

RSpec.describe TrainingVideoLength do
  let(:youtube_lesson) { build(:training_lesson, video_url: "https://www.youtube.com/watch?v=abcDEF12345") }
  let(:vimeo_lesson) { build(:training_lesson, video_url: "https://vimeo.com/123456") }

  describe "YouTube" do
    it "reads the ISO 8601 duration from the Data API" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return("example-key")
      stub_request(:get, "https://www.googleapis.com/youtube/v3/videos")
        .with(query: { part: "contentDetails", id: "abcDEF12345", key: "example-key" })
        .to_return(status: 200, body: { items: [ { contentDetails: { duration: "PT4M13S" } } ] }.to_json)

      expect(described_class.for(youtube_lesson)).to eq(253)
    end

    it "doesn't call out without an API key" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:youtube, :api_key).and_return(nil)

      expect(described_class.for(youtube_lesson)).to be_nil
      expect(described_class).not_to be_youtube_configured
    end

    it "gives up quietly on an unknown video or an error" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return("example-key")
      stub_request(:get, %r{googleapis\.com/youtube}).to_return(status: 200, body: { items: [] }.to_json)
      expect(described_class.for(youtube_lesson)).to be_nil

      stub_request(:get, %r{googleapis\.com/youtube}).to_return(status: 403, body: "{}")
      expect(described_class.for(youtube_lesson)).to be_nil
    end
  end

  describe "Vimeo" do
    it "reads the length from public oEmbed" do
      stub_request(:get, "https://vimeo.com/api/oembed.json")
        .with(query: { url: "https://vimeo.com/123456" })
        .to_return(status: 200, body: { duration: 563 }.to_json)

      expect(described_class.for(vimeo_lesson)).to eq(563)
    end

    it "returns nil when embedding is turned off" do
      stub_request(:get, %r{vimeo\.com/api/oembed}).to_return(status: 403, body: "")
      expect(described_class.for(vimeo_lesson)).to be_nil
    end

    it "returns nil when Vimeo can't be reached" do
      stub_request(:get, %r{vimeo\.com/api/oembed}).to_timeout
      expect(described_class.for(vimeo_lesson)).to be_nil
    end
  end
end
