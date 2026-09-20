# allow corrections after submission

priority: high. evidence: source review.

onboarding edits are blocked once a registration is awaiting a guardian or complete. travel has a separate edit route, but health, guardian, and emergency contact information lack equivalent attendee correction routes.

a wrong guardian email is especially frustrating: the attendee can resend an invitation to the wrong address but cannot correct it. health requirements and contact details can also change before the event.

proposed behavior:

- provide an edit or request-change action beside each submitted section.
- allow routine corrections directly where they do not invalidate consent or require review.
- explain any effect on documents, signatures, guardian verification, or registration status before committing a consequential change.
- route changes that require staff involvement into a visible request with pending, approved, or follow-up-needed status.
- provide a clear way to correct the guardian destination and issue the appropriate replacement invitation, with verification and handling of existing consent determined by the guardian-change rules.
- retain an audit history and notify the appropriate staff when operationally important details change.

acceptance criteria:

- an attendee can correct contact information or find a specific change-request action without searching for a general support address.
- changing a guardian does not silently carry over the previous guardian's consent.
- submitting registration does not leave the attendee with an unqualified cannot-be-edited message.
- the attendee can see the updated value or the state of their pending request.

code references: [registration lock](../app/controllers/onboarding_controller.rb), [dashboard actions](../app/controllers/dashboard_controller.rb), [event dashboard](../app/views/dashboard/show.html.erb).
