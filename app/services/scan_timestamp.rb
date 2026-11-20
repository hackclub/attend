# Decides when a scan happened, given what the scanning device claims.
#
# A door device that lost its connection replays scans minutes or hours late,
# so the server's receive time is not when the person walked in. But a device
# clock can't be trusted outright either. So the device sends two readings of
# its own clock: when it scanned and when it sent this request. Their
# difference is how long the scan waited, which is right however wrong the
# clock is, and is subtracted from the server's time.
#
# Without a send time the scan time is compared with the server clock
# directly. Either way the claim is only honoured inside the bounds below;
# outside them the scan is recorded at the server's time. The device's raw
# claim is kept on the scan (`client_scanned_at`) in every case.
class ScanTimestamp
  # How long a scan may have waited on a device before its time is no longer
  # believed.
  MAX_AGE = 24.hours
  # Slack for a scan that claims to be slightly newer than its own send time
  # or than the server clock.
  MAX_FUTURE_SKEW = 2.minutes

  Result = Data.define(:scanned_at, :client_scanned_at, :adjusted) do
    def adjusted?
      adjusted
    end
  end

  def self.resolve(client_scanned_at:, client_sent_at: nil, now: Time.current)
    claimed = parse(client_scanned_at)
    return Result.new(scanned_at: now, client_scanned_at: nil, adjusted: false) unless claimed

    age = (parse(client_sent_at) || now) - claimed

    if age > MAX_AGE || age < -MAX_FUTURE_SKEW
      Result.new(scanned_at: now, client_scanned_at: claimed, adjusted: true)
    else
      Result.new(scanned_at: now - [ age, 0 ].max, client_scanned_at: claimed, adjusted: false)
    end
  end

  def self.parse(value)
    return value.in_time_zone if value.respond_to?(:in_time_zone) && !value.is_a?(String)
    return if value.blank?

    Time.iso8601(value.to_s).in_time_zone
  rescue ArgumentError
    nil
  end
  private_class_method :parse
end
