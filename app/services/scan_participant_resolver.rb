class ScanParticipantResolver
  DEEP_LINK_PATTERN = /\Aattend:\/\/checkin\/(.+)\z/

  def self.call(event:, identifier:, includes: [])
    identifier = normalize(identifier)
    return if identifier.blank?

    participant_events = event.participant_events
    participant_events = participant_events.includes(*includes) if includes.any?

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
