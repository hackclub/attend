class NfcTokenResolver
  UUID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

  def self.call(event:, token:)
    new(event: event, token: token).call
  end

  def initialize(event:, token:)
    @event = event
    @token = token
  end

  def call
    return nil unless token.to_s.match?(UUID_PATTERN)

    personal_token = NfcToken.includes(user: :participant).find_by(token: token)
    return participation_for(personal_token.user.participant) if personal_token&.active?
    return nil if personal_token

    legacy = ParticipantEvent.includes(participant: :user).find_by(nfc_badge_token: token)
    return nil unless legacy&.nfc_badge_assigned_at?

    linked_participant = legacy.participant.user&.participant
    return participation_for(linked_participant) if linked_participant

    legacy if legacy.event_id == event.id
  end

  private

  attr_reader :event, :token

  def participation_for(participant)
    participant&.participant_events&.find_by(event: event)
  end
end
