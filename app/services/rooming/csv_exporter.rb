module Rooming
  class CsvExporter
    def initialize(event)
      @event = event
    end

    def generate
      rooms = @event.rooms
        .includes(room_assignments: { participant_event: :participant })
        .order(:name, :created_at)

      CSV.generate do |csv|
        csv << [
          "Room Number",
          "Legal First Name",
          "Legal Last Name",
          "Date of Birth",
          "Age at Event"
        ]

        rooms.each do |room|
          if room.staff_only? && room.staff_names.present?
            room.staff_names.split(/[,;]/).map(&:strip).reject(&:blank?).each do |staff_name|
              csv << [
                room.name || room.display_name,
                staff_name,
                "(Staff)",
                nil,
                nil
              ]
            end
          else
            room.room_assignments.each do |assignment|
              participant = assignment.participant_event.participant
              age = participant.age_on(@event.starts_at&.to_date || Date.current)

              csv << [
                room.name || room.display_name,
                participant.legal_first_name,
                participant.legal_last_name,
                participant.date_of_birth&.iso8601,
                age
              ]
            end
          end
        end
      end
    end
  end
end
