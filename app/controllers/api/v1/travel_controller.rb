class Api::V1::TravelController < ApplicationController
  before_action :authenticate_user!

  def search_airports
    keyword = params[:keyword].to_s.strip
    airports = AeroDataBoxService.search_airports(keyword)
    render json: { airports: airports }
  end

  def validate_flight
    flight_code = params[:flight_code].to_s.strip
    departure_date = params[:departure_date]

    carrier_code = AirlineDataService.parse_carrier_code(flight_code)
    airline = AirlineDataService.lookup(carrier_code)
    airline_info = airline || { code: carrier_code, name: carrier_code, logo_url: AirlineDataService.logo_url(carrier_code) }

    if flight_code.blank?
      render json: { valid: false, error: "Flight code is required" }
      return
    end

    unless flight_code.match?(/\A[A-Z0-9\s]{2,10}\z/i)
      render json: { valid: false, error: "Invalid flight code format" }
      return
    end

    # Flight data is now entered manually (OAG lookup was removed to cut cost).
    # We still return the static airline badge for the flight code, but no
    # airports/times — the traveller fills those in themselves.
    render json: {
      valid: false,
      manual: true,
      flight_code: flight_code.upcase.gsub(/\s+/, ""),
      carrier: carrier_code,
      airline: airline_info
    }
  end
end
