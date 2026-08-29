class ProcessImportBatchJob < ApplicationJob
  queue_as :default

  INVITE_DELAY_SECONDS = 1.0

  def perform(import_batch_id)
    @batch = ImportBatch.find(import_batch_id)
    @event = @batch.event
    @errors = []

    return if @batch.completed? || @batch.failed?

    begin
      import_participants
      send_invitations_with_rate_limit if @batch.send_invitations
      complete_batch
    rescue StandardError => e
      fail_batch(e)
    end
  end

  private

  def import_participants
    @batch.update!(status: :importing)
    @batch.broadcast_progress

    @participants_to_invite = []

    @batch.rows_data.each_with_index do |row, index|
      row = row.with_indifferent_access
      next if row[:email].blank?

      begin
        result = import_row(row, index + 2)
        if result[:imported]
          @batch.increment!(:imported_count)
          @participants_to_invite << result[:participant] if result[:participant]
        else
          @batch.increment!(:skipped_count)
          add_error(index + 2, row[:email], result[:reason])
        end
      rescue StandardError => e
        @batch.increment!(:error_count)
        add_error(index + 2, row[:email], e.message)
        Rails.logger.error("[ProcessImportBatchJob] Row #{index + 2} error: #{e.message}")
      end

      @batch.broadcast_progress
    end
  end

  def import_row(row, row_number)
    email = row[:email]&.downcase&.strip
    return { imported: false, reason: "No email" } if email.blank?

    existing_participant = Participant.find_by("LOWER(email) = ?", email)
    existing_pe = existing_participant&.participant_events&.find_by(event: @event)

    if existing_pe
      return { imported: false, reason: "Already registered for this event" }
    end

    participant = nil

    ActiveRecord::Base.transaction do
      participant = find_or_create_participant(row, existing_participant)
      participant_event = create_participant_event(participant)

      create_accommodation(participant_event, row)
      create_dietary(participant_event, row)
      create_medical(participant_event, row)
      create_guardian_and_emergency_contact(participant_event, row, row_number)
      create_travel(participant_event, row)
    end

    { imported: true, participant: participant }
  end

  def send_invitations_with_rate_limit
    return if @participants_to_invite.empty?

    @batch.update!(status: :sending_invites)
    @batch.broadcast_progress

    @participants_to_invite.each do |participant|
      begin
        ParticipantMailer.invitation(
          email: participant.email,
          event: @event,
          participant: participant
        ).deliver_later
        @batch.increment!(:invites_sent_count)
      rescue StandardError => e
        add_error(nil, participant.email, "Failed to send invitation: #{e.message}")
        Rails.logger.error("[ProcessImportBatchJob] Failed to send invitation to #{participant.email}: #{e.message}")
      end

      @batch.broadcast_progress
      sleep(INVITE_DELAY_SECONDS)
    end
  end

  def complete_batch
    @batch.update!(status: :completed, completed_at: Time.current, rows_data: [])
    @batch.broadcast_progress
  end

  def fail_batch(error)
    Rails.logger.error("[ProcessImportBatchJob] Batch #{@batch.id} failed: #{error.message}\n#{error.backtrace.first(10).join("\n")}")
    add_error(nil, nil, "Import failed: #{error.message}")
    @batch.update!(status: :failed, completed_at: Time.current, rows_data: [])
    @batch.broadcast_progress
  end

  def add_error(row, email, message, increment_count: false)
    @batch.errors_data << { row: row, email: email, error: message }
    @batch.increment!(:error_count) if increment_count
    @batch.save!
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
      tshirt_size: normalize_tshirt_size(row[:tshirt_size])
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

  def create_accommodation(participant_event, row)
    return unless row[:gender].present?

    gender = normalize_gender(row[:gender])
    return unless gender

    Accommodation.create!(
      participant_event: participant_event,
      gender_identity: gender
    )
  end

  GENDER_MAPPING = {
    "female" => "female",
    "male" => "male",
    "non_binary" => "non_binary",
    "non-binary" => "non_binary",
    "nonbinary" => "non_binary",
    "trans_female" => "trans_female",
    "trans female" => "trans_female",
    "trans_male" => "trans_male",
    "trans male" => "trans_male",
    "other" => "other"
  }.freeze

  def normalize_gender(gender_str)
    return nil if gender_str.blank?

    normalized = gender_str.to_s.downcase.strip
    GENDER_MAPPING[normalized]
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

  def create_guardian_and_emergency_contact(participant_event, row, row_number)
    if row[:parent_email].present?
      # A sheet where the parent column was filled in with the participant's own
      # address would otherwise mail the minor their own guardian invite. Import
      # the participant anyway and flag the row so an admin can chase the real
      # parent address.
      if parent_email_matches_participant?(row)
        add_error(row_number, row[:email], "Parent email is the same as the participant's email - guardian not created")
      else
        guardian = find_or_create_guardian(row)
        create_guardian_participant_event(participant_event, guardian)
      end
    end

    if row[:emergency_first_name].present? && row[:emergency_phone].present?
      create_emergency_contact(participant_event, row)
    end
  end

  def parent_email_matches_participant?(row)
    row[:parent_email].to_s.strip.downcase == row[:email].to_s.strip.downcase
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

    phone = normalize_phone(row[:emergency_phone])
    if phone.nil? && row[:emergency_phone].present?
      raise ArgumentError, "Emergency contact phone #{row[:emergency_phone].inspect} is not a valid phone number. Include the country code, for example +1 415 555 0132."
    end

    EmergencyContact.create!(
      participant_event: participant_event,
      name: name,
      phone: phone,
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
    row[:flight_1_departure_airport].present? || row[:flight_1_number].present?
  end

  def create_flight_travel(participant_event, row)
    if row[:flight_1_departure_airport].present?
      inbound = Travel.create!(
        participant_event: participant_event,
        direction: :inbound,
        mode: :plane,
        origin_address: row[:origin_address].presence
      )
      create_inbound_flight_legs(inbound, row)
    end

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

  TRAVEL_MODE_MAPPING = {
    "flight" => "plane",
    "plane" => "plane",
    "car" => "car",
    "train" => "train",
    "bus" => "bus",
    "other" => "other"
  }.freeze

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

  # Returns E.164, or nil when the cell isn't a real number. See the matching
  # note in CsvImportService: never fall back to the raw string.
  def normalize_phone(phone_str)
    return nil if phone_str.blank?

    normalized = PhoneNormalizer.normalize(phone_str)
    if normalized.nil?
      Rails.logger.warn("[ProcessImportBatchJob] Dropping unparseable phone number #{phone_str.inspect}")
    end
    normalized
  end

  def normalize_tshirt_size(size_str)
    return nil if size_str.blank?

    normalized = size_str.to_s.downcase.strip
    TSHIRT_SIZE_MAPPING[normalized] || size_str.upcase
  end

  def parse_date(date_str)
    return nil if date_str.blank?

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

    Date.parse(date_str)
  rescue ArgumentError
    nil
  end
end
