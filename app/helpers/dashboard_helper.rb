module DashboardHelper
  def wallet_pass_url(participant_event)
    return if ENV["PASSKIT_WEB_SERVICE_HOST"].blank?

    Passkit::UrlGenerator.new(Passkit::EventTicket, participant_event).ios
  end

  def google_wallet_url(participant_event)
    ::GoogleWallet::EventTicket.new(participant_event).save_url
  end

  def extract_airline_iata(flight_code)
    return nil if flight_code.blank?

    # Flight codes are like "BA123", "OS7801", "3U8392", "U21234"
    # Extract the airline code (2-3 alphanumeric chars) before the flight number
    match = flight_code.strip.upcase.match(/\A([A-Z0-9]{2})(\d)/)
    return match[1] if match

    # Try 3-letter ICAO codes (all letters) - less common in user input
    match = flight_code.strip.upcase.match(/\A([A-Z]{3})(\d)/)
    return nil unless match

    # Convert common ICAO to IATA
    icao_to_iata = {
      "BAW" => "BA", "DLH" => "LH", "AFR" => "AF", "KLM" => "KL", "AUA" => "OS",
      "SWR" => "LX", "AAL" => "AA", "UAL" => "UA", "DAL" => "DL"
    }
    icao_to_iata[match[1]]
  end

  DISPLAY_STATUS_STYLES = {
    "Complete" => "bg-green-100 text-green-800",
    "Awaiting Participant" => "bg-blue-100 text-blue-800",
    "Awaiting Parent" => "bg-amber-100 text-amber-800",
    "Withdrawn" => "bg-red-100 text-red-800",
    "Rejected" => "bg-red-100 text-red-800"
  }.freeze

  def display_status_badge_class(display_status)
    DISPLAY_STATUS_STYLES[display_status] || "bg-gray-100 text-gray-800"
  end

  COMPLETION_STATUS_STYLES = {
    confirmed: "bg-green-100 text-green-800",
    information_needed: "bg-blue-100 text-blue-800",
    action_needed: "bg-blue-100 text-blue-800",
    waiting_on_guardian: "bg-amber-100 text-amber-800",
    waiting_on_participant: "bg-amber-100 text-amber-800",
    paused: "bg-amber-100 text-amber-800",
    staff_attention: "bg-red-100 text-red-800",
    preparing: "bg-gray-100 text-gray-800",
    processing: "bg-gray-100 text-gray-800",
    withdrawn: "bg-red-100 text-red-800",
    rejected: "bg-red-100 text-red-800"
  }.freeze

  def completion_status_badge_class(state)
    COMPLETION_STATUS_STYLES.fetch(state, "bg-gray-100 text-gray-800")
  end
end
