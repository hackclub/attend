require "csv"

class CsvImportService
  class ImportError < StandardError; end

  COLUMN_MAPPING = {
    "Email" => :email,
    "First Name" => :legal_first_name,
    "Last Name" => :legal_last_name,
    "Preferred Name" => :preferred_name,
    "Slack ID" => :slack_id,
    "Pronouns" => :pronouns,
    "Gender" => :gender,
    "Phone Number" => :phone,
    "Birthday" => :date_of_birth,
    "Address Line 1" => :address_line_1,
    "Address Line 2" => :address_line_2,
    "City" => :city,
    "State" => :state,
    "ZIP Code" => :postal_code,
    "Country" => :country,
    "T-Shirt Size" => :tshirt_size,
    "Parent First Name" => :parent_first_name,
    "Parent Last Name" => :parent_last_name,
    "Parent Email" => :parent_email,
    "Parent Phone" => :parent_phone,
    "Emergency Contact First Name" => :emergency_first_name,
    "Emergency Contact Last Name" => :emergency_last_name,
    "Emergency Contact Email" => :emergency_email,
    "Emergency Contact Phone" => :emergency_phone,
    "Emergency Contact Relationship" => :emergency_relationship,
    "Do you have any dietary requirements we need to know about?" => :dietary_requirements,
    "Do you have any special requirements e.g. medication, or disabilities that we need to be aware of?" => :medical_requirements,
    "How are you getting to Prototype?" => :travel_mode,
    "Starting Address" => :origin_address,
    "How many flights are on your itinerary for your journey to SFO / SJO / OAK?" => :num_inbound_flights,
    "Flight 1 Departing Airport" => :flight_1_departure_airport,
    "Flight 1 Arriving Airport" => :flight_1_arrival_airport,
    "Flight 1 Airline Code" => :flight_1_airline,
    "Flight 1 Flight Number" => :flight_1_number,
    "Flight 1 Departing Date" => :flight_1_date,
    "Flight 2 Departing Airport" => :flight_2_departure_airport,
    "Flight 2 Arriving Airport" => :flight_2_arrival_airport,
    "Flight 2 Airline Code" => :flight_2_airline,
    "Flight 2 Flight Number" => :flight_2_number,
    "Flight 2 Departing Date" => :flight_2_date,
    "Flight 3 Departing Airport" => :flight_3_departure_airport,
    "Flight 3 Arriving Airport" => :flight_3_arrival_airport,
    "Flight 3 Airline Code" => :flight_3_airline,
    "Flight 3 Flight Number" => :flight_3_number,
    "Flight 3 Departing Date" => :flight_3_date,
    "Final Departure Airport" => :outbound_departure_airport,
    "Final Airline Code" => :outbound_airline,
    "Final Flight Number" => :outbound_flight_number,
    "Flight Departure Date" => :outbound_date,
    "Last Leg Departing Airport" => :last_leg_departure_airport,
    "Last Leg Arriving Airport" => :last_leg_arrival_airport,
    "Last Leg Airline Code" => :last_leg_airline,
    "Last Leg Flight Number" => :last_leg_number,
    "Last Leg Departing Date" => :last_leg_date,
    "Groups" => :groups
  }.freeze

  TSHIRT_SIZE_MAPPING = {
    "xs" => "XS",
    "s" => "S",
    "m" => "M",
    "l" => "L",
    "xl" => "XL",
    "xxl" => "XXL",
    "2xl" => "XXL",
    "xxxl" => "XXXL",
    "3xl" => "XXXL"
  }.freeze

  TRAVEL_MODE_MAPPING = {
    "flight" => "plane",
    "plane" => "plane",
    "car" => "car",
    "train" => "train",
    "bus" => "bus",
    "other" => "other"
  }.freeze

  Result = Struct.new(:success, :imported_count, :skipped_count, :errors, keyword_init: true) do
    def success?
      success
    end
  end

  def initialize(event:, send_invitations: true)
    @event = event
    @send_invitations = send_invitations
    @errors = []
    @imported_count = 0
    @skipped_count = 0
  end

  def import(csv_content)
    rows = parse_csv(csv_content)

    rows.each_with_index do |row, index|
      next if row[:email].blank?

      begin
        import_row(row, index + 2) # +2 for 1-indexed + header row
      rescue StandardError => e
        @errors << { row: index + 2, email: row[:email], error: e.message }
        Rails.logger.error("[CsvImportService] Row #{index + 2} error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      end
    end

    Result.new(
      success: @errors.empty?,
      imported_count: @imported_count,
      skipped_count: @skipped_count,
      errors: @errors
    )
  end

  private

  def parse_csv(csv_content)
    # Force UTF-8 encoding and remove BOM if present
    csv_content = csv_content.force_encoding("UTF-8")
    csv_content = csv_content.sub(/\A\xEF\xBB\xBF/u, "")

    csv = CSV.parse(csv_content, headers: true)

    csv.map do |row|
      mapped = {}
      row.each do |header, value|
        key = COLUMN_MAPPING[header]
        mapped[key] = value&.strip if key
      end
      mapped
    end
  end

  def import_row(row, row_number)
    email = row[:email]&.downcase&.strip
    return if email.blank?

    existing_participant = Participant.find_by("LOWER(email) = ?", email)
    existing_pe = existing_participant&.participant_events&.find_by(event: @event)

    if existing_pe
      @skipped_count += 1
      @errors << { row: row_number, email: email, error: "Already registered for this event" }
      return
    end

    ActiveRecord::Base.transaction do
      participant = find_or_create_participant(row, existing_participant)
      participant_event = create_participant_event(participant)

      create_accommodation(participant_event, row)
      create_dietary(participant_event, row)
      create_medical(participant_event, row)
      create_guardian_and_emergency_contact(participant_event, row)
      create_travel(participant_event, row)
      apply_groups(participant_event, row)

      send_invitation(participant) if @send_invitations

      @imported_count += 1
    end
  end

  def find_or_create_participant(row, existing)
    attrs = {
      legal_first_name: row[:legal_first_name],
      legal_last_name: row[:legal_last_name],
      preferred_name: row[:preferred_name].presence,
      email: row[:email]&.downcase&.strip,
      pronouns: row[:pronouns].presence,
      phone: normalize_phone(row[:phone]),
      date_of_birth: parse_date(row[:date_of_birth]),
      address_line_1: row[:address_line_1].presence,
      address_line_2: row[:address_line_2].presence,
      city: row[:city].presence,
      state: row[:state].presence,
      postal_code: row[:postal_code].presence,
      country_of_residence: row[:country].presence,
      tshirt_size: normalize_tshirt_size(row[:tshirt_size]),
      slack_user_id: row[:slack_id].presence
    }.compact

    if existing
      existing.update!(attrs.except(:email))
      existing
    else
      Participant.create!(attrs)
    end
  end

  def create_participant_event(participant)
    ParticipantEvent.create!(
      participant: participant,
      event: @event,
      status: :invited
    )
  end

  def apply_groups(participant_event, row)
    return unless @event.groups_enabled?
    return if row[:groups].blank?

    names = row[:groups].split(/[;,]/).map(&:strip).reject(&:blank?)
    return if names.empty?

    existing_group_ids = GroupMembership.where(participant_event: participant_event).pluck(:group_id).to_set

    names.each do |name|
      group = @event.groups.find_by("LOWER(name) = ?", name.downcase) ||
              @event.groups.find_by("LOWER(slug) = ?", name.downcase)
      group ||= @event.groups.create!(name: name)
      next if existing_group_ids.include?(group.id)
      GroupMembership.create!(group: group, participant_event: participant_event)
      existing_group_ids << group.id
    end
  end

  def create_accommodation(participant_event, row)
    return unless row[:gender].present?

    Accommodation.create!(
      participant_event: participant_event,
      gender_identity: row[:gender]&.downcase
    )
  end

  def create_dietary(participant_event, row)
    return unless row[:dietary_requirements].present?

    dietary_text = row[:dietary_requirements]
    is_allergy = dietary_text.to_s.downcase.include?("allerg")

    Dietary.create!(
      participant_event: participant_event,
      life_threatening_allergies: is_allergy ? dietary_text : nil,
      notes: is_allergy ? nil : dietary_text
    )
  end

  def create_medical(participant_event, row)
    return unless row[:medical_requirements].present?

    medical_text = row[:medical_requirements]
    return if medical_text.to_s.downcase.in?(%w[n/a na none no nil nothing nope -])

    Medical.create!(
      participant_event: participant_event,
      medical_conditions: medical_text
    )
  end

  def create_guardian_and_emergency_contact(participant_event, row)
    if row[:parent_email].present?
      guardian = find_or_create_guardian(row)
      create_guardian_participant_event(participant_event, guardian)
    end

    if row[:emergency_first_name].present? && row[:emergency_phone].present?
      create_emergency_contact(participant_event, row)
    end
  end

  def find_or_create_guardian(row)
    email = row[:parent_email]&.downcase&.strip
    guardian = Guardian.find_by("LOWER(email) = ?", email)

    attrs = {
      legal_first_name: row[:parent_first_name],
      legal_last_name: row[:parent_last_name],
      email: email,
      phone: normalize_phone(row[:parent_phone])
    }.compact

    if guardian
      guardian.update!(attrs.except(:email))
      guardian
    else
      Guardian.create!(attrs)
    end
  end

  def create_guardian_participant_event(participant_event, guardian)
    GuardianParticipantEvent.create!(
      guardian: guardian,
      participant_event: participant_event,
      is_primary_guardian: true,
      status: :pending
    )
  end

  def create_emergency_contact(participant_event, row)
    name = [ row[:emergency_first_name], row[:emergency_last_name] ].compact.join(" ")
    return if name.blank?

    EmergencyContact.create!(
      participant_event: participant_event,
      name: name,
      phone: normalize_phone(row[:emergency_phone]),
      email: row[:emergency_email].presence,
      relationship: row[:emergency_relationship].presence,
      priority: 1
    )
  end

  def create_travel(participant_event, row)
    mode = determine_travel_mode(row[:travel_mode])

    if mode == "plane" || has_flight_data?(row)
      create_flight_travel(participant_event, row)
    elsif mode.present?
      create_simple_travel(participant_event, row, mode)
    end
  end

  def has_flight_data?(row)
    row[:flight_1_departure_airport].present? ||
      row[:flight_1_number].present?
  end

  def create_flight_travel(participant_event, row)
    # Inbound travel
    if row[:flight_1_departure_airport].present?
      inbound = Travel.create!(
        participant_event: participant_event,
        direction: :inbound,
        mode: :plane,
        origin_address: row[:origin_address].presence
      )

      create_inbound_flight_legs(inbound, row)
    end

    # Outbound travel
    if row[:outbound_departure_airport].present? || row[:outbound_flight_number].present?
      outbound = Travel.create!(
        participant_event: participant_event,
        direction: :outbound,
        mode: :plane
      )

      create_outbound_flight_legs(outbound, row)
    end
  end

  def create_inbound_flight_legs(travel, row)
    num_flights = row[:num_inbound_flights].to_i
    num_flights = 1 if num_flights < 1

    (1..[ num_flights, 3 ].min).each do |i|
      departure_airport = row[:"flight_#{i}_departure_airport"]
      arrival_airport = row[:"flight_#{i}_arrival_airport"]
      airline = row[:"flight_#{i}_airline"]
      flight_number = row[:"flight_#{i}_number"]
      date_str = row[:"flight_#{i}_date"]

      next if departure_airport.blank? && flight_number.blank?

      flight_code = [ airline, flight_number ].compact.join("").presence

      leg = TravelLeg.new(
        travel: travel,
        position: i - 1,
        departure_airport: departure_airport&.upcase,
        arrival_airport: arrival_airport&.upcase,
        flight_code: flight_code,
        departure_time: parse_date(date_str)&.beginning_of_day
      )
      leg.save!(validate: false)
    end
  end

  def create_outbound_flight_legs(travel, row)
    # Primary outbound flight
    if row[:outbound_departure_airport].present? || row[:outbound_flight_number].present?
      flight_code = [ row[:outbound_airline], row[:outbound_flight_number] ].compact.join("").presence
      departure_date = parse_date(row[:outbound_date])

      leg = TravelLeg.new(
        travel: travel,
        position: 0,
        departure_airport: row[:outbound_departure_airport]&.upcase,
        flight_code: flight_code,
        departure_time: departure_date&.beginning_of_day
      )
      leg.save!(validate: false)
    end

    # Last leg (connecting flight home)
    if row[:last_leg_departure_airport].present?
      flight_code = [ row[:last_leg_airline], row[:last_leg_number] ].compact.join("").presence

      leg = TravelLeg.new(
        travel: travel,
        position: 1,
        departure_airport: row[:last_leg_departure_airport]&.upcase,
        arrival_airport: row[:last_leg_arrival_airport]&.upcase,
        flight_code: flight_code,
        departure_time: parse_date(row[:last_leg_date])&.beginning_of_day
      )
      leg.save!(validate: false)
    end
  end

  def create_simple_travel(participant_event, row, mode)
    Travel.create!(
      participant_event: participant_event,
      direction: :inbound,
      mode: mode,
      origin_address: row[:origin_address].presence
    )
  end

  def determine_travel_mode(mode_str)
    return nil if mode_str.blank?

    normalized = mode_str.to_s.downcase.strip
    TRAVEL_MODE_MAPPING[normalized] || begin
      if normalized.include?("fly") || normalized.include?("flight") || normalized.include?("plane")
        "plane"
      elsif normalized.include?("car") || normalized.include?("driv")
        "car"
      elsif normalized.include?("train")
        "train"
      elsif normalized.include?("bus")
        "bus"
      else
        "other"
      end
    end
  end

  def send_invitation(participant)
    ParticipantMailer.invitation(
      email: participant.email,
      event: @event,
      participant: participant
    ).deliver_later
  rescue StandardError => e
    Rails.logger.error("[CsvImportService] Failed to send invitation to #{participant.email}: #{e.message}")
    @errors << { email: participant.email, error: "Imported but failed to send invitation: #{e.message}" }
  end

  def normalize_phone(phone_str)
    return nil if phone_str.blank?

    if phone_str.start_with?("+")
      parsed = Phonelib.parse(phone_str)
      parsed.valid? ? parsed.e164 : phone_str
    else
      parsed = Phonelib.parse(phone_str, nil)
      parsed.valid? ? parsed.e164 : phone_str
    end
  end

  def normalize_tshirt_size(size_str)
    return nil if size_str.blank?

    normalized = size_str.to_s.downcase.strip
    TSHIRT_SIZE_MAPPING[normalized] || size_str.upcase
  end

  def parse_date(date_str)
    return nil if date_str.blank?

    # Check if year looks like 4 digits (has a 4-digit number)
    has_four_digit_year = date_str.match?(/\b\d{4}\b/)

    if has_four_digit_year
      formats = [ "%m/%d/%Y", "%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y" ]
    else
      formats = [ "%m/%d/%y", "%d/%m/%y" ]
    end

    formats.each do |format|
      begin
        return Date.strptime(date_str, format)
      rescue ArgumentError
        next
      end
    end

    # Fallback to Date.parse
    Date.parse(date_str)
  rescue ArgumentError
    nil
  end

  def parse_datetime(datetime_str)
    return nil if datetime_str.blank?

    # If it's just a date, return start of day
    date = parse_date(datetime_str)
    return date.beginning_of_day if date

    DateTime.parse(datetime_str)
  rescue ArgumentError
    nil
  end
end
