class ScanRecorder
  Result = Data.define(:scan, :outcome, :first_scanned_at, :deduplicated) do
    def first_scan_in_context?
      outcome == "scanned"
    end

    def deduplicated?
      deduplicated
    end
  end

  def self.call(**attributes)
    new(**attributes).call
  end

  def initialize(participant_event:, user:, scan_context:, scanned_at:, client_scan_id:, source:)
    @participant_event = participant_event
    @user = user
    @scan_context = scan_context
    @scanned_at = scanned_at
    @client_scan_id = client_scan_id.presence
    @source = source
  end

  def call
    participant_event.with_lock do
      existing_retry = context_scans.find_by(client_scan_id: client_scan_id) if client_scan_id
      return result_for(existing_retry) if existing_retry

      first_scan = context_scans.order(:created_at, :id).first
      scan = participant_event.scans.create!(
        user: user,
        scan_context: scan_context,
        scanned_at: scanned_at,
        client_scan_id: client_scan_id,
        source: source
      )

      Result.new(
        scan: scan,
        outcome: first_scan ? "already_scanned" : "scanned",
        first_scanned_at: first_scan&.scanned_at || scan.scanned_at,
        deduplicated: false
      )
    end
  rescue ActiveRecord::RecordNotUnique
    retry_scan = context_scans.find_by(client_scan_id: client_scan_id)
    raise unless retry_scan

    result_for(retry_scan)
  end

  private

  attr_reader :participant_event, :user, :scan_context, :scanned_at, :client_scan_id, :source

  def context_scans
    participant_event.scans.where(scan_context: scan_context)
  end

  def result_for(scan)
    first_scan = context_scans.order(:created_at, :id).first!
    Result.new(
      scan: scan,
      outcome: first_scan.id == scan.id ? "scanned" : "already_scanned",
      first_scanned_at: first_scan.scanned_at,
      deduplicated: true
    )
  end
end
