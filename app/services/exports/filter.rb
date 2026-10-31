module Exports
  # One row filter: a registry field, an operator valid for the field's type,
  # and (for most operators) a comparison value. Matching happens in Ruby on
  # the extracted value so computed fields filter identically to columns.
  #
  # Date and time values are read on `time_zone`, the exported event's clock:
  # a datetime-local value like "2026-07-12T09:30" is that wall-clock time
  # there, and a bare date is that calendar day there.
  class Filter
    OPERATORS_BY_TYPE = {
      string: %w[contains not_contains equals present blank],
      boolean: %w[true false],
      date: %w[on before after present blank],
      datetime: %w[on before after present blank],
      enum: %w[in not_in present blank]
    }.freeze

    VALUELESS_OPERATORS = %w[present blank true false].freeze

    OPERATOR_LABELS = {
      "contains" => "contains",
      "not_contains" => "does not contain",
      "equals" => "equals",
      "present" => "is present",
      "blank" => "is blank",
      "true" => "is yes",
      "false" => "is no",
      "in" => "is any of",
      "not_in" => "is none of",
      "on" => "is on",
      "before" => "is before",
      "after" => "is after"
    }.freeze

    attr_reader :field, :operator, :value, :time_zone

    def self.build(params, time_zone: nil)
      field = FieldRegistry.fetch(params["field"].to_s)
      return nil unless field

      new(field: field, operator: params["operator"].to_s, value: params["value"], time_zone: time_zone)
    end

    def initialize(field:, operator:, value: nil, time_zone: nil)
      @field = field
      @operator = operator
      @value = value
      @time_zone = time_zone || Time.zone
    end

    def valid?
      return false unless field.filterable?
      return false unless OPERATORS_BY_TYPE.fetch(field.type, []).include?(operator)
      return true if VALUELESS_OPERATORS.include?(operator)

      case field.type
      when :date, :datetime then parsed_time.present?
      when :enum then enum_values.present? && (enum_values - field.enum_values.map(&:to_s)).empty?
      else value.to_s.present?
      end
    end

    def matches?(participant_event)
      actual = field.extractor.call(participant_event)

      case operator
      when "present" then actual.present?
      when "blank" then actual.blank?
      when "true" then !!actual
      when "false" then !actual
      when "contains" then actual.to_s.downcase.include?(value.to_s.downcase)
      when "not_contains" then !actual.to_s.downcase.include?(value.to_s.downcase)
      when "equals" then actual.to_s.downcase == value.to_s.downcase
      when "in" then enum_values.include?(actual.to_s)
      when "not_in" then !enum_values.include?(actual.to_s)
      when "on" then actual.present? && local_date(actual) == parsed_time.to_date
      when "before" then actual.present? && (by_day? ? local_date(actual) < parsed_time.to_date : actual.to_time < parsed_time)
      when "after" then actual.present? && (by_day? ? local_date(actual) > parsed_time.to_date : actual.to_time > parsed_time)
      else false
      end
    end

    def to_h
      { "field" => field.key, "operator" => operator, "value" => value }
    end

    private

    def enum_values
      Array(value).map(&:to_s).reject(&:blank?)
    end

    def parsed_time
      @parsed_time ||= time_zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # "before 2026-07-01" means before that day starts; "after 2026-07-01"
    # means after that day ends, so a bare date behaves intuitively. Those
    # compare calendar days on the event's clock.
    def by_day?
      field.type == :date || date_only_value?
    end

    # The calendar day a value falls on at the event; a plain date is its own day.
    def local_date(actual)
      actual.in_time_zone(time_zone).to_date
    end

    def date_only_value?
      value.to_s.strip.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    end
  end
end
