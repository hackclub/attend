class GeocoderService
  BASE_URL = "https://geocoder.hackclub.com/v1/geocode".freeze

  def self.geocode(address)
    return nil if address.blank?

    api_key = ENV["GEOCODER_API_KEY"] || Rails.application.credentials.dig(:geocoder, :api_key)
    return nil if api_key.blank?

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
end
