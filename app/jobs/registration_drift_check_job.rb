# Counts registrations whose stored status isn't what their requirements say
# it should be. Every change that affects a requirement re-syncs the status,
# so this should stay at zero; anything else means a path is missing its sync.
# Reports only, never repairs: `rake registration:sync` does that.
class RegistrationDriftCheckJob < ApplicationJob
  queue_as :default

  PRELOADS = [
    :consents, :travel_inbound, :travel_outbound, :accommodation, :medical, :dietary,
    :accessibility, :emergency_contacts, :participant, { event: :custom_documents },
    { guardian_participant_events: :emergency_contacts }
  ].freeze

  # Registrations at events that haven't ended (those are frozen as they are).
  def self.live_registrations(scope = ParticipantEvent.all)
    scope.active.joins(:event)
      .where("events.ends_at IS NULL OR events.ends_at >= ?", Time.current)
      .includes(*PRELOADS)
  end

  def self.drifted(scope = ParticipantEvent.all)
    live_registrations(scope).find_each.select do |participant_event|
      participant_event.registration_requirements.stage != participant_event.status
    end
  end

  def perform
    drifted = self.class.drifted
    Appsignal.set_gauge("registration_status_drift", drifted.size) if defined?(Appsignal)
    return if drifted.empty?

    by_event = drifted.group_by(&:event_id).transform_values(&:size)
    Rails.logger.warn("[RegistrationDriftCheckJob] #{drifted.size} registrations have drifted from their requirements: #{by_event}")
  end
end
