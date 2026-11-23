# Records one scan for the admin scanner and the API alike, so both get the
# same retry handling and the same bounds on a device's claimed scan time.
class ScanRecorder
  # A client_scan_id names one scan: one person at one scan point. Seen again
  # for anything else, it is a client bug or a forged request.
  class ClientScanIdConflict < StandardError
    def initialize(msg = "This scan id was already used for a different scan")
      super
    end
  end

  Result = Data.define(:scan, :outcome, :first_scanned_at, :deduplicated, :time_adjusted) do
    def first_scan_in_context?
      outcome == "scanned"
    end

    def deduplicated?
      deduplicated
    end

    # True when the device's time for the scan was out of bounds and the
    # server's was recorded instead. Always false for a retry.
    def time_adjusted?
      time_adjusted
    end
  end

  def self.call(**attributes)
    new(**attributes).call
  end

  # `client_scanned_at` and `client_sent_at` are the device's own claims;
  # ScanTimestamp decides how far they are believed.
  def initialize(participant_event:, user:, scan_context:, client_scan_id:, source:, client_scanned_at: nil, client_sent_at: nil)
    @participant_event = participant_event
    @user = user
    @scan_context = scan_context
    @client_scan_id = client_scan_id.presence
    @source = source
    @client_scanned_at = client_scanned_at
    @client_sent_at = client_sent_at
  end

  def call
    participant_event.with_lock do
      existing_retry = retry_of_existing_scan
      return result_for(existing_retry) if existing_retry

      # Resolved under the lock, so scans sent without a device time are
      # ordered as they were recorded.
      timestamp = ScanTimestamp.resolve(client_scanned_at: client_scanned_at, client_sent_at: client_sent_at)
      earliest = earliest_scan
      scan = participant_event.scans.create!(
        user: user,
        scan_context: scan_context,
        scanned_at: timestamp.scanned_at,
        client_scan_id: client_scan_id,
        client_scanned_at: timestamp.client_scanned_at,
        source: source
      )
      # "First" goes by when the scan happened, as check-in time does
      # (ParticipantEvent#check_in_time), not by when it reached us: a scan
      # held on a device while offline can be older than one already here.
      first = earliest.nil? || scan.scanned_at < earliest.scanned_at

      Result.new(
        scan: scan,
        outcome: first ? "scanned" : "already_scanned",
        first_scanned_at: first ? scan.scanned_at : earliest.scanned_at,
        deduplicated: false,
        time_adjusted: timestamp.adjusted?
      )
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
    # Lost a race for the id: answer as a retry, or as a conflict.
    raise unless client_scan_id_taken?(error)

    retry_scan = retry_of_existing_scan
    raise unless retry_scan

    result_for(retry_scan)
  end

  private

  attr_reader :participant_event, :user, :scan_context, :client_scan_id, :source, :client_scanned_at, :client_sent_at

  def context_scans
    participant_event.scans.where(scan_context: scan_context)
  end

  def earliest_scan
    context_scans.order(:scanned_at, :created_at, :id).first
  end

  # The scan already recorded under this id, if this is a retry of it.
  def retry_of_existing_scan
    return unless client_scan_id

    existing = Scan.find_by(client_scan_id: client_scan_id)
    return unless existing

    if existing.participant_event_id != participant_event.id || existing.scan_context_id != scan_context.id
      raise ClientScanIdConflict
    end

    existing
  end

  def client_scan_id_taken?(error)
    return false unless client_scan_id

    case error
    when ActiveRecord::RecordInvalid
      error.record.errors.of_kind?(:client_scan_id, :taken)
    else
      error.message.include?("index_scans_on_client_scan_id")
    end
  end

  def result_for(scan)
    earliest = earliest_scan
    Result.new(
      scan: scan,
      outcome: earliest.id == scan.id ? "scanned" : "already_scanned",
      first_scanned_at: earliest.scanned_at,
      deduplicated: true,
      time_adjusted: false
    )
  end
end
