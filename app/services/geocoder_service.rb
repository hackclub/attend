class GeocoderService
  BASE_URL = "https://geocoder.hackclub.com/v1/geocode".freeze

  def self.geocode(address)
    return nil if address.blank?

    api_key = self.api_key
    if api_key.blank?
      # Without a key every address quietly comes back nil, which looked like
      # bad addresses on prod for months. Make the misconfiguration loud.
      Rails.logger.warn("GeocoderService: no API key configured, skipping '#{address}'")
      return nil
    end

    response = Faraday.get(BASE_URL, {
      address: address,
      key: api_key
    })

    if response.success?
      data = JSON.parse(response.body)
      if data["lat"].present? && data["lng"].present?
        {
          latitude: data["lat"].to_d,
          longitude: data["lng"].to_d,
          formatted_address: data["formatted_address"]
        }
      end
    end
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.error("Geocoding failed for '#{address}': #{e.message}")
    nil
  end

  # The env var is what dev uses; production credentials store the key at the
  # top level as geocoder_api_key, with the nested form kept for anything
  # still configured that way.
  def self.api_key
    ENV["GEOCODER_API_KEY"].presence ||
      Rails.application.credentials.geocoder_api_key.presence ||
      Rails.application.credentials.dig(:geocoder, :api_key)
  end
end
