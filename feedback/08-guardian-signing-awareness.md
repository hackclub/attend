# make the parent or guardian signing requirement unmistakable

priority: high. evidence: user-reported attendee confusion, supported by the source review of the handoff.

attendees did not understand that their parent or guardian also had to sign. entering a guardian's contact details and submitting the attendee form could feel like the end of registration, even though entry eligibility depended on further action by another person.

the requirement needs to appear at meaningful points in the journey, not only in a confirmation message after a long form.

proposed behavior:

- explain in the invitation and at the beginning of registration that under-18 attendees need their parent or guardian to complete their portion, including signatures.
- use the event-age rule already used by registration rather than assuming that current age determines the requirement.
- on the guardian details step, explain exactly what will be sent, to whom, and when.
- before submission, show the guardian destination and explain that submitting the attendee form does not finish the guardian's tasks.
- after submission, show a prominent task: "your parent/guardian needs to sign" with the destination, invitation status, and resend or correction action.
- explicitly connect this requirement to ticket availability. name all remaining blockers rather than implying the guardian signature is always the only one.
- notify the attendee when registration is confirmed and the entry ticket is ready.
- handle paused invitations honestly instead of presenting a send action that will only fail.

suggested copy when applicable:

> your part is submitted. your parent/guardian must complete their forms and sign before your registration can be confirmed. we sent their invitation to [email]. please ask them to check their inbox.

acceptance criteria:

- before submitting, an attendee can explain that their own submission is only one part of registration.
- the dashboard names who must act next and provides the appropriate action.
- adults do not see a guardian requirement that does not apply to them.
- completing guardian requirements removes the prompt, with any remaining attendee tasks shown accurately.
- comprehension checks ask attendees what their parent must do and when their ticket becomes available.

code references: [invitation](../app/views/participant_mailer/invitation.html.erb), [guardian details](../app/views/onboarding/guardian.html.erb), [submission](../app/controllers/onboarding_controller.rb), [guardian dashboard card](../app/views/dashboard/show.html.erb).

related: [consistent completion states](03-consistent-completion-states.md), [corrections after submission](02-corrections-after-submission.md).
