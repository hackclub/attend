# Pulls a consent's signature state from the DocuSeal API off the request
# path. The signing pages poll every few seconds; the poll answers from the
# database and hands the (throttled) API round-trip to this job, so the next
# poll sees whatever it found.
class SyncConsentFromDocusealJob < ApplicationJob
  queue_as :default

  def perform(consent_id)
    consent = Consent.find_by(id: consent_id)
    return if consent.nil? || consent.signed? || consent.voided?

    consent.sync_from_docuseal!
  end
end
