# Shared by the pages that poll for a DocuSeal signature (the participant's
# documents step, the guardian's signing pages). The embedded form's
# "completed" event is the fast path off those pages, but it doesn't always
# reach us (signed in the "open in a new tab" window, a dropped postMessage),
# so they also ask the server every few seconds.
module DocusealStatusPolling
  extend ActiveSupport::Concern

  # Hitting the DocuSeal API every few seconds for every outstanding document
  # would be rude, and the webhook usually gets there first anyway. Sync at
  # most once per consent per window — the plain DB read on every poll is
  # what actually carries the webhook's update through to the page.
  DOCUSEAL_POLL_THROTTLE = 15.seconds

  private

  def sync_from_docuseal_throttled(consent)
    return if consent.docuseal_envelope_id.blank?

    key = "docuseal_status_poll/#{consent.id}"
    return if Rails.cache.read(key)
    Rails.cache.write(key, true, expires_in: DOCUSEAL_POLL_THROTTLE)

    consent.sync_from_docuseal!
  end
end
