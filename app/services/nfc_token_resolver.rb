class NfcTokenResolver
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def self.call(event:, token:)
    new(event: event, token: token).call
  end

  def initialize(event:, token:)
    @event = event
    @token = token.to_s.strip
  end

  def call
    return unless UUID_PATTERN.match?(token)

    event_badge = participant_events
      .where.not(nfc_badge_assigned_at: nil)
      .find_by(nfc_badge_token: token)
    return event_badge if event_badge

    passport = Passport.active.includes(user: :participant).find_by(token: token)
    participant = passport&.user&.participant
    return unless participant

    participant_events.find_by(participant_id: participant.id)
  end

  private

  attr_reader :event, :token

  def participant_events
    @participant_events ||= event.participant_events.includes(
      :participant,
      :medical,
      :dietary,
      :safeguarding_info
    )
  end
end
