# The one status staff see for a registration. Before any scan places them,
# it's their registration status; after one, it's where their latest placing
# scan puts them; once the event has ended, whether they attended. Computed
# from scans and display_status, never stored.
#
# Tones: :done (green), :wait (amber), :live (blue, with staff right now),
# :idle (grey, nothing to act on).
class ParticipantStatusPresenter
  # Each status: [word, tone, what the word means].
  REGISTRATION = {
    "Complete" => [ "Registration complete", :done, "Registered, with every step and document done. No scan has placed them yet." ],
    "Awaiting Parent" => [ "Awaiting parent", :wait, "Registration is waiting on a parent or guardian." ],
    "Awaiting Participant" => [ "Awaiting participant", :wait, "Registration is waiting on the participant." ],
    "Withdrawn" => [ "Not coming", :idle, "Withdrawn from the event." ],
    "Rejected" => [ "Rejected", :idle, "Registration was rejected by staff." ]
  }.freeze

  WHEREABOUTS = {
    "venue" => [ "At venue", :done, "Their latest scan was arriving at the venue." ],
    "lodging" => [ "At lodging", :done, "Their latest scan was at lodging, or leaving the venue for the night." ],
    "pickup" => [ "Picked up", :live, "Staff collected them on their way in. They haven't been scanned at the venue or lodging since." ],
    "supervised_outing" => [ "Out supervised", :live, "Their latest scan was leaving with staff, like a bus tour." ],
    "outing" => [ "Out", :wait, "Their latest scan was leaving without staff, like free time or an errand." ],
    "departure" => [ "Signed out", :idle, "Their latest scan was leaving the event." ]
  }.freeze

  ATTENDED = [ "Attended", :done, "The event has ended, and a scan placed them at it at least once." ].freeze
  NO_SHOW = [ "No-show", :wait, "The event has ended, and no scan ever placed them at it." ].freeze

  attr_reader :label, :tone, :meaning, :scan

  def initialize(participant_event, now: Time.current)
    @participant_event = participant_event
    @now = now
    @scan = participant_event.latest_placing_scan unless gone?
    @label, @tone, @meaning = resolve
  end

  # When the scan behind the status happened, on the event's clock: "09:14"
  # today, "Tue 22:10" on another day. Nil for registration statuses.
  def scanned_at_label
    return unless scan

    @scanned_at_label ||= begin
      at = scan.scanned_at.in_time_zone(event.event_time_zone)
      at.to_date == @now.in_time_zone(at.time_zone).to_date ? at.strftime("%H:%M") : at.strftime("%a %H:%M")
    end
  end

  # Plain text for a hover title: what the word means, and the scan behind it.
  def explanation
    return meaning unless scan

    "#{meaning} #{scan.scan_context.name} · #{scanned_at_label}."
  end

  private

  attr_reader :participant_event

  def event
    participant_event.event
  end

  def gone?
    participant_event.withdrawn? || participant_event.rejected?
  end

  def resolve
    registration = REGISTRATION.fetch(participant_event.display_status)
    return registration if gone?
    return (scan ? ATTENDED : NO_SHOW) if ended?

    place = WHEREABOUTS[scan.scan_context.effective_kind] if scan
    return place if place

    @scan = nil # its point became tracking only mid-request, so it places nobody
    registration
  end

  def ended?
    event.ends_at.present? && @now >= event.ends_at
  end
end
