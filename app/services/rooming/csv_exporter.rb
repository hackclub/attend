module Rooming
  class CsvExporter
    # `include_date_of_birth: false` drops the DOB column entirely, for the
    # PII-restricted roles that can run rooming but not see exact birthdays.
    # Age at Event is kept either way — it's what the sheet is actually for.
    def initialize(event, include_date_of_birth: true)
      @event = event
      @include_date_of_birth = include_date_of_birth
    end

    def generate
      rooms = @event.rooms
        .includes(room_assignments: { participant_event: :participant })
        .order(:name, :created_at)

      CSV.generate do |csv|
        csv << row(
          "Room Number",
          "Legal First Name",
          "Legal Last Name",
          "Date of Birth",
          "Age at Event"
        )

        rooms.each do |room|
          if room.staff_only? && room.staff_names.present?
            room.staff_names.split(/[,;]/).map(&:strip).reject(&:blank?).each do |staff_name|
              csv << row(
                room.name || room.display_name,
                staff_name,
                "(Staff)",
                nil,
                nil
              )
            end
          else
            room.room_assignments.each do |assignment|
              participant = assignment.participant_event.participant
              age = participant.age_on(@event.starts_at&.to_date || Date.current)

              csv << row(
                room.name || room.display_name,
                participant.legal_first_name,
                participant.legal_last_name,
                participant.date_of_birth&.iso8601,
                age
              )
            end
          end
        end
      end
    end

    private

    # Positional so the header and body can't drift out of step: the fourth
    # value is always the date of birth, and it's dropped or kept as one.
    def row(room, first_name, last_name, date_of_birth, age)
      values = [ room, first_name, last_name, date_of_birth, age ]
      values.delete_at(3) unless @include_date_of_birth
      values
    end
  end
end
