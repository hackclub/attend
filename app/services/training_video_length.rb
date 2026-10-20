# Looks up a lesson video's real length from where it's hosted, so a
# must-watch video's length is known without an admin previewing it
# (TrainingLesson#known_video_duration). YouTube needs a Data API key, which is
# free; Vimeo's public oEmbed carries the length with no key. Returns seconds,
# or nil when it can't tell — the admin preview and the lesson form are the
# fallbacks.
class TrainingVideoLength
  YOUTUBE_URL = "https://www.googleapis.com/youtube/v3/videos".freeze
  VIMEO_OEMBED_URL = "https://vimeo.com/api/oembed.json".freeze
  TIMEOUT = 10

  def self.for(lesson)
    case lesson.video_source
    when :youtube then youtube(lesson.video_id)
    when :vimeo then vimeo(lesson.video_id)
    end
  end

  def self.youtube_configured?
    youtube_api_key.present?
  end

  def self.youtube(video_id)
    api_key = youtube_api_key
    return nil if api_key.blank?

    data = get_json(YOUTUBE_URL, part: "contentDetails", id: video_id, key: api_key)
    iso_duration = data&.dig("items", 0, "contentDetails", "duration")
    positive(ActiveSupport::Duration.parse(iso_duration).to_i) if iso_duration.present?
  rescue ActiveSupport::Duration::ISO8601Parser::ParsingError => e
    Rails.logger.warn("[TrainingVideoLength] Unreadable YouTube duration for #{video_id}: #{e.message}")
    nil
  end

  # Fails (403) when the owner has turned embedding off — but then the lesson
  # couldn't play it either.
  def self.vimeo(video_id)
    data = get_json(VIMEO_OEMBED_URL, url: "https://vimeo.com/#{video_id}")
    positive(data&.dig("duration"))
  end

  def self.youtube_api_key
    ENV["YOUTUBE_API_KEY"] || Rails.application.credentials.dig(:youtube, :api_key)
  end

  def self.get_json(url, params)
    response = Faraday.new(request: { timeout: TIMEOUT, open_timeout: TIMEOUT }).get(url, params)
    unless response.success?
      Rails.logger.warn("[TrainingVideoLength] #{URI(url).host} answered #{response.status}")
      return nil
    end

    JSON.parse(response.body)
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.warn("[TrainingVideoLength] #{URI(url).host} lookup failed: #{e.class}: #{e.message}")
    nil
  end

  def self.positive(value)
    number = Float(value, exception: false)
    number if number&.finite? && number.positive?
  end

  private_class_method :get_json, :positive, :youtube_api_key
end
