class FlightEta
  Result = Struct.new(
    :eta, :eta_source, :scheduled, :delay_minutes, :is_delayed,
    :status, :raw_status,
    keyword_init: true
  ) do
    def cancelled? = status == :cancelled
    def diverted? = status == :diverted
    def landed?   = status == :landed
    def picked_up? = status == :picked_up
    def in_flight? = status == :in_flight
    def scheduled? = status == :scheduled
    def alert? = cancelled? || diverted? || (is_delayed && !landed? && !picked_up?)
    def known_eta? = !eta.nil?
  end

  RAW_STATUS_MAP = {
    "Scheduled"  => :scheduled,
    "Delayed"    => :scheduled,
    "Departed"   => :in_flight,
    "EnRoute"    => :in_flight,
    "En Route"   => :in_flight,
    "InAir"      => :in_flight,
    "In Air"     => :in_flight,
    "Arrived"    => :landed,
    "Landed"     => :landed,
    "Cancelled"  => :cancelled,
    "Canceled"   => :cancelled,
    "Diverted"   => :diverted
  }.freeze

  DELAY_THRESHOLD = 15.minutes

  def self.for(leg, picked_up: nil)
    new(leg, picked_up: picked_up).result
  end

  def initialize(leg, picked_up: nil)
    @leg = leg
    @picked_up_override = picked_up
    @tracking = leg.respond_to?(:live_tracking_data) ? (leg.live_tracking_data || {}) : {}
  end

  def result
    Result.new(
      eta:            eta_time,
      eta_source:     eta_source,
      scheduled:      scheduled_time,
      delay_minutes:  delay_minutes,
      is_delayed:     delay_minutes >= (DELAY_THRESHOLD / 60),
      status:         normalised_status,
      raw_status:     raw_status
    )
  end

  private

  attr_reader :leg, :tracking

  def picked_up?
    return @picked_up_override unless @picked_up_override.nil?
    leg.respond_to?(:picked_up?) && leg.picked_up?
  end

  def raw_status
    @raw_status ||= (leg.respond_to?(:live_status) ? leg.live_status : nil)
  end

  def normalised_status
    base = RAW_STATUS_MAP[raw_status.to_s] || :scheduled
    return :picked_up if base == :landed && picked_up?
    base
  end

  # When status is Arrived, FlightAware's parser puts the actual landing time
  # into `predicted_arrival` (estimated_in || actual_in). We treat it as :actual.
  def eta_time
    @eta_time ||= eta_with_source.first
  end

  def eta_source
    @eta_source ||= eta_with_source.last
  end

  def eta_with_source
    @eta_with_source ||= begin
      if normalised_status == :landed || normalised_status == :picked_up
        [ parse_time(tracking[:predicted_arrival]) || parse_time(tracking[:scheduled_arrival]) || leg.try(:live_arrival_time) || leg.try(:arrival_time), :actual ]
      elsif (t = parse_time(tracking[:predicted_arrival]))
        [ t, :predicted ]
      elsif (t = parse_time(tracking[:scheduled_arrival]))
        [ t, :scheduled ]
      elsif (t = leg.try(:live_arrival_time))
        [ t, :live_stored ]
      elsif (t = leg.try(:arrival_time))
        [ t, :stored ]
      else
        [ nil, nil ]
      end
    end
  end

  def scheduled_time
    @scheduled_time ||= parse_time(tracking[:scheduled_arrival]) || leg.try(:arrival_time)
  end

  def delay_minutes
    return 0 if scheduled_time.nil?
    return 0 if eta_time.nil?
    return 0 if eta_source == :stored # comparing scheduled vs scheduled
    diff = ((eta_time - scheduled_time) / 60.0).round
    diff.positive? ? diff : 0
  end

  def parse_time(value)
    return nil if value.blank?
    case value
    when Time, ActiveSupport::TimeWithZone, DateTime then value.to_time
    when Date then value.to_time
    when String
      Time.parse(value) rescue nil
    else
      value.respond_to?(:to_time) ? value.to_time : nil
    end
  end
end
