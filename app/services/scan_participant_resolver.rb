class ScanParticipantResolver
  DEEP_LINK_PATTERN = /\Aattend:\/\/checkin\/(.+)\z/i

  # A signed check-in code (see CheckinCode) is checked before it is looked
  # up, and raises CheckinCode::Invalid when its signature or event is wrong:
  # that is a forged or foreign ticket, not a participant we don't know.
  # Anything else is taken as an id, as it always was.
  def self.call(event:, identifier:, includes: [])
    identifier = normalize(identifier)
    return if identifier.blank?

    participant_events = event.participant_events
    participant_events = participant_events.includes(*includes) if includes.any?

    if CheckinCode.signed?(identifier)
      return participant_events.find_by(id: CheckinCode.verify!(identifier, event: event))
    end

    participant_events.find_by(id: identifier) ||
      participant_events.joins(:participant).find_by(participants: { id: identifier })
  end

  def self.normalize(identifier)
    identifier = identifier.to_s.strip
    deep_link_match = identifier.match(DEEP_LINK_PATTERN)
    (deep_link_match ? deep_link_match[1] : identifier).strip
  end

  private_class_method :normalize
end
