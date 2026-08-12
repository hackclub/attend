require "csv"

module Exports
  class CsvBuilder
    attr_reader :row_count

    def initialize(event:, columns:, filters: [], row_mode: "participant")
      @event = event
      @fields = columns.map { |key| FieldRegistry.fetch(key) }.compact
      @filters = filters
      @row_mode = row_mode
      @row_count = 0
    end

    def to_csv
      CSV.generate do |csv|
        csv << @fields.map(&:label)

        scope.each do |pe|
          next unless @filters.all? { |f| f.matches?(pe) }

          if @row_mode == "flight_leg"
            append_leg_rows(csv, pe)
          else
            csv << row_for(pe)
            @row_count += 1
          end
        end
      end
    end

    private

    def scope
      keys = @fields.map(&:key) + @filters.map { |f| f.field.key }
      includes = FieldRegistry.includes_for(keys)
      includes << { travels: :travel_legs } if @row_mode == "flight_leg"
      @event.participant_events.includes(:participant, *includes.uniq)
    end

    def append_leg_rows(csv, pe)
      pe.travels.select(&:plane?).each do |travel|
        travel.travel_legs.sort_by { |leg| leg.position.to_i }.each do |leg|
          csv << @fields.map { |field| format_value(extract(field, pe, leg, travel)) }
          @row_count += 1
        end
      end
    end

    def row_for(pe)
      @fields.map do |field|
        # Leg-level fields have no single value on a participant row.
        field.leg_level? ? nil : format_value(extract(field, pe))
      end
    end

    def extract(field, pe, leg = nil, travel = nil)
      field.leg_level? ? field.extractor.call(pe, leg, travel) : field.extractor.call(pe)
    end

    def format_value(value)
      case value
      when true then "Yes"
      when false then "No"
      when Time, ActiveSupport::TimeWithZone, DateTime then value.strftime("%Y-%m-%d %H:%M")
      when Date then value.iso8601
      else value
      end
    end
  end
end
