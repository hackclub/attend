class AirlineDataService
  AIRLINES = {
    "AA" => { name: "American Airlines", country: "United States" },
    "AC" => { name: "Air Canada", country: "Canada" },
    "AF" => { name: "Air France", country: "France" },
    "AI" => { name: "Air India", country: "India" },
    "AM" => { name: "Aeromexico", country: "Mexico" },
    "AS" => { name: "Alaska Airlines", country: "United States" },
    "AY" => { name: "Finnair", country: "Finland" },
    "AZ" => { name: "ITA Airways", country: "Italy" },
    "BA" => { name: "British Airways", country: "United Kingdom" },
    "BR" => { name: "EVA Air", country: "Taiwan" },
    "CA" => { name: "Air China", country: "China" },
    "CX" => { name: "Cathay Pacific", country: "Hong Kong" },
    "CZ" => { name: "China Southern", country: "China" },
    "DL" => { name: "Delta Air Lines", country: "United States" },
    "EI" => { name: "Aer Lingus", country: "Ireland" },
    "EK" => { name: "Emirates", country: "United Arab Emirates" },
    "ET" => { name: "Ethiopian Airlines", country: "Ethiopia" },
    "EW" => { name: "Eurowings", country: "Germany" },
    "EY" => { name: "Etihad Airways", country: "United Arab Emirates" },
    "FI" => { name: "Icelandair", country: "Iceland" },
    "FR" => { name: "Ryanair", country: "Ireland" },
    "GA" => { name: "Garuda Indonesia", country: "Indonesia" },
    "HA" => { name: "Hawaiian Airlines", country: "United States" },
    "HU" => { name: "Hainan Airlines", country: "China" },
    "IB" => { name: "Iberia", country: "Spain" },
    "JL" => { name: "Japan Airlines", country: "Japan" },
    "KE" => { name: "Korean Air", country: "South Korea" },
    "KL" => { name: "KLM", country: "Netherlands" },
    "LA" => { name: "LATAM Airlines", country: "Chile" },
    "LH" => { name: "Lufthansa", country: "Germany" },
    "LO" => { name: "LOT Polish Airlines", country: "Poland" },
    "LX" => { name: "Swiss International", country: "Switzerland" },
    "MH" => { name: "Malaysia Airlines", country: "Malaysia" },
    "MS" => { name: "EgyptAir", country: "Egypt" },
    "MU" => { name: "China Eastern", country: "China" },
    "NH" => { name: "All Nippon Airways", country: "Japan" },
    "NZ" => { name: "Air New Zealand", country: "New Zealand" },
    "OK" => { name: "Czech Airlines", country: "Czech Republic" },
    "OS" => { name: "Austrian Airlines", country: "Austria" },
    "OZ" => { name: "Asiana Airlines", country: "South Korea" },
    "PC" => { name: "Pegasus Airlines", country: "Turkey" },
    "PR" => { name: "Philippine Airlines", country: "Philippines" },
    "QF" => { name: "Qantas", country: "Australia" },
    "QR" => { name: "Qatar Airways", country: "Qatar" },
    "RJ" => { name: "Royal Jordanian", country: "Jordan" },
    "SA" => { name: "South African Airways", country: "South Africa" },
    "SK" => { name: "SAS Scandinavian", country: "Sweden" },
    "SN" => { name: "Brussels Airlines", country: "Belgium" },
    "SQ" => { name: "Singapore Airlines", country: "Singapore" },
    "SU" => { name: "Aeroflot", country: "Russia" },
    "SV" => { name: "Saudia", country: "Saudi Arabia" },
    "TG" => { name: "Thai Airways", country: "Thailand" },
    "TK" => { name: "Turkish Airlines", country: "Turkey" },
    "TP" => { name: "TAP Air Portugal", country: "Portugal" },
    "UA" => { name: "United Airlines", country: "United States" },
    "UX" => { name: "Air Europa", country: "Spain" },
    "VA" => { name: "Virgin Australia", country: "Australia" },
    "VN" => { name: "Vietnam Airlines", country: "Vietnam" },
    "VS" => { name: "Virgin Atlantic", country: "United Kingdom" },
    "VY" => { name: "Vueling", country: "Spain" },
    "WN" => { name: "Southwest Airlines", country: "United States" },
    "WS" => { name: "WestJet", country: "Canada" },
    "XQ" => { name: "SunExpress", country: "Turkey" },
    "ZH" => { name: "Shenzhen Airlines", country: "China" },
    "U2" => { name: "easyJet", country: "United Kingdom" },
    "W6" => { name: "Wizz Air", country: "Hungary" },
    "6E" => { name: "IndiGo", country: "India" },
    "9W" => { name: "Jet Airways", country: "India" },
    "2P" => { name: "PAL Express", country: "Philippines" },
    "3K" => { name: "Jetstar Asia", country: "Singapore" },
    "5J" => { name: "Cebu Pacific", country: "Philippines" },
    "7C" => { name: "Jeju Air", country: "South Korea" },
    "8M" => { name: "Myanmar Airways", country: "Myanmar" },
    "9C" => { name: "Spring Airlines", country: "China" }
  }.freeze

  class << self
    def lookup(carrier_code)
      return nil if carrier_code.blank?

      code = carrier_code.to_s.upcase.strip
      airline = AIRLINES[code]

      return nil unless airline

      {
        code: code,
        name: airline[:name],
        country: airline[:country],
        logo_url: logo_url(code)
      }
    end

    def logo_url(carrier_code)
      "https://pics.avs.io/200/80/#{carrier_code}.png"
    end

    def parse_carrier_code(flight_code)
      return nil if flight_code.blank?

      cleaned = flight_code.to_s.strip.upcase.gsub(/\s+/, "")
      match = cleaned.match(/^([A-Z]{2}|\d[A-Z]|[A-Z]\d)(\d+)$/)
      match ? match[1] : nil
    end
  end
end
