class RegenerateWaiversForDateChangeJob < ApplicationJob
  queue_as :default

  # Runs after Admin::WaiverRegenerationsController has re-cloned the event's
  # templates with the new dates: voids every issued waiver and re-issues it on
  # the new template. One participant failing mustn't strand everyone after
  # them, so each is handled (and logged) on its own.
  def perform(event_id, include_signed:)
    event = Event.find(event_id)
    regeneration = Docuseal::WaiverDateRegeneration.new(event)

    consents = regeneration.consents_to_reissue(include_signed: include_signed)
      .includes(:guardian_participant_event, participant_event: [ :participant, :safeguarding_info ])
      .to_a
      .group_by(&:participant_event)

    reissued = 0
    consents.each do |participant_event, participant_consents|
      reissued += 1 if regeneration.reissue!(participant_event, participant_consents)
    rescue => e
      Rails.logger.error(
        "[RegenerateWaiversForDateChangeJob] Couldn't re-issue waivers for participant_event #{participant_event.id}: #{e.class} - #{e.message}"
      )
      Rails.error.report(e, handled: true)
    end

    Rails.logger.info("[RegenerateWaiversForDateChangeJob] Re-issued waivers for #{reissued} of #{consents.size} participants at event #{event.id}")
  end
end
