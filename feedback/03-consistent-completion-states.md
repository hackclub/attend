# give attendees and guardians consistent completion states

priority: high. evidence: source review.

the attendee documents step supports signing before submission. the guardian confirmation page nevertheless says that the attendee still needs to sign whenever the guardian has signed, without checking the attendee signature. it can also announce that the guardian portion is complete while showing an outstanding waiver below.

these messages make it difficult for families to know who needs to act. this document concerns state accuracy; [guardian signing awareness](08-guardian-signing-awareness.md) concerns explaining the requirement in the first place.

proposed behavior:

- derive the next action from outstanding tasks and their owner, including attendee, guardian, staff, or document processing.
- distinguish information submitted, your tasks complete, waiting on someone else, and registration confirmed.
- use the same task state for dashboard summaries, confirmation pages, and notifications.
- never ask someone to sign a document they have already signed.
- explain paused documents and signature processing as waiting states, with an appropriate next action or notification promise.

example: "your information is submitted. your parent/guardian still needs to sign the event waiver. we sent their invitation to [email]."

acceptance criteria:

- both attendee-first and guardian-first signing orders produce accurate messages.
- a completed guardian profile with an unsigned waiver is not described as all guardian tasks complete.
- custom documents and optional activities that have been added are included in the outstanding-task calculation.
- delayed signature processing is distinguishable from a missing signature.
- the dashboard's confirmed state agrees with entry-pass eligibility.

code references: [participant event status](../app/models/participant_event.rb), [documents step](../app/views/onboarding/documents.html.erb), [guardian confirmation](../app/views/guardian_portal/confirmed.html.erb), [dashboard summary](../app/views/dashboard/index.html.erb).
