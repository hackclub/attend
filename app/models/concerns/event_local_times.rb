# Times typed into datetime-local fields, read on the event's clock.
#
# Those fields submit zone-less strings like "2026-07-12T09:30", which Rails
# would cast in the app default zone (UTC). A model declares its typed times
# with `event_local_times`; each raw string is kept and re-parsed in
# `event_local_time_zone` once validation runs, by which point an event or
# timezone submitted in the same form has been assigned. A value that names
# its own offset (or is already a Time) is left alone.
#
# `flag:` is for tables whose older rows were saved before this, when typed
# times landed as UTC wall-clock. It names a boolean column that is false on
# those rows: they keep rendering on UTC, exactly as typed, and forms prefill
# them that way too. The first time any of a legacy row's times is assigned
# again, its other times are moved onto the event's clock as well and the
# flag flips, so a row never mixes the two readings. New rows start flagged.
module EventLocalTimes
  extend ActiveSupport::Concern

  NAIVE_DATETIME_PATTERN = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?\z/
  FIELD_FORMAT = "%Y-%m-%dT%H:%M"
  UTC = ActiveSupport::TimeZone["UTC"]

  class_methods do
    def event_local_times(*attrs, flag: nil)
      class_attribute :event_local_time_attributes, instance_writer: false
      class_attribute :event_local_time_flag, instance_writer: false
      self.event_local_time_attributes = attrs.map(&:to_sym).freeze
      self.event_local_time_flag = flag

      # The column defaults to false so rows written any other way (an older
      # deploy mid-rollout, raw SQL) read as legacy; rows built here are new.
      attribute flag, :boolean, default: true if flag

      event_local_time_attributes.each do |attr|
        define_method(:"#{attr}=") do |value|
          raw = value.is_a?(String) ? value.strip : nil
          (@event_local_time_input ||= {})[attr] = raw&.match?(NAIVE_DATETIME_PATTERN) ? raw : :instant
          super(value)
        end
      end

      before_validation :interpret_event_local_times
    end
  end

  # The zone typed times are read in. Defaults to the record's event.
  def event_local_time_zone
    event&.event_time_zone
  end

  # The zone to show this record's times in: UTC for a legacy row, whose
  # times are the typed wall-clock stored as UTC.
  def time_display_zone
    return UTC if legacy_event_local_times?

    event_local_time_zone || UTC
  end

  def local_time(attr)
    self[attr]&.in_time_zone(time_display_zone)
  end

  # Value for a datetime-local field, on the same clock the row displays on.
  def local_time_field_value(attr)
    local_time(attr)&.strftime(FIELD_FORMAT)
  end

  private

  def legacy_event_local_times?
    event_local_time_flag.present? && !self[event_local_time_flag]
  end

  def interpret_event_local_times
    input = @event_local_time_input
    return if input.blank?

    zone = event_local_time_zone
    return if zone.nil?

    # An API client echoing back a legacy row's instant hasn't retyped it;
    # only a typed wall-clock or a real change moves the row onto the
    # event's clock.
    input = input.reject { |attr, raw| raw == :instant && !will_save_change_to_attribute?(attr) }
    @event_local_time_input = nil
    return if input.empty?

    if legacy_event_local_times?
      (event_local_time_attributes - input.keys).each do |attr|
        self[attr] = reinterpret_utc_wall_clock(self[attr], zone) if self[attr]
      end
      self[event_local_time_flag] = true
    end

    input.each do |attr, raw|
      next if raw == :instant

      parsed = begin
        zone.parse(raw)
      rescue ArgumentError
        nil
      end
      self[attr] = parsed if parsed
    end
  end

  def reinterpret_utc_wall_clock(time, zone)
    utc = time.utc
    zone.local(utc.year, utc.month, utc.day, utc.hour, utc.min, utc.sec)
  end
end
