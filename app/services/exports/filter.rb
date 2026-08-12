module Exports
  # One row filter: a registry field, an operator valid for the field's type,
  # and (for most operators) a comparison value. Matching happens in Ruby on
  # the extracted value so computed fields filter identically to columns.
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

    attr_reader :field, :operator, :value

    def self.build(params)
      field = FieldRegistry.fetch(params["field"].to_s)
      return nil unless field

      new(field: field, operator: params["operator"].to_s, value: params["value"])
    end

    def initialize(field:, operator:, value: nil)
      @field = field
      @operator = operator
      @value = value
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
      when "on" then actual.present? && actual.to_date == parsed_time.to_date
      when "before" then actual.present? && actual.to_time < comparison_time(end_of_day: false)
      when "after" then actual.present? && actual.to_time > comparison_time(end_of_day: true)
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
      @parsed_time ||= Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    # "before 2026-07-01" means before that day starts; "after 2026-07-01"
    # means after that day ends, so a bare date behaves intuitively.
    def comparison_time(end_of_day:)
      time = parsed_time
      return time unless field.type == :date || date_only_value?

      end_of_day ? time.end_of_day : time.beginning_of_day
    end

    def date_only_value?
      value.to_s.strip.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    end
  end
end
