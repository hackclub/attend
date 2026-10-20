class SyncUcatBansJob < ApplicationJob
  queue_as :default

  # The enrollment alert runs even when the sync raises (e.g. the safety
  # limit): the bans already in Attend are still worth checking against.
  def perform(force: false)
    result = Bans::UcatSync.new(force: force).call
    Rails.logger.info("[SyncUcatBansJob] #{result.to_h}")
    result
  ensure
    alert_upcoming_enrollments
  end

  private

  def alert_upcoming_enrollments
    participant_events = Ban.upcoming_enrollments.to_a
    recipients = BanMailer.alert_recipients
    return if participant_events.empty? || recipients.empty?

    BanMailer.upcoming_enrollments(participant_events: participant_events, recipients: recipients).deliver_later
  end
end
