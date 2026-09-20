# make the invitation a useful starting brief

priority: medium. evidence: source review.

the invitation explains the broad process and provides a reply contact, but omits event dates, a completion deadline, expected effort, and the required headshot. it describes guardian information universally despite the adult flow. account-email mismatches can produce a generic no-invitation message without a useful recovery explanation.

proposed behavior:

- include event dates and location, what the invitation means, and what is required to confirm attendance.
- provide a real completion deadline where configured and an effort estimate validated against actual use.
- list what to have ready, including a face photo and guardian contact details when applicable.
- explain what can be completed later and that progress can be resumed, once autosave reliably supports this promise.
- explain the guardian signing requirement and when their invitation is sent.
- use consistent registration terminology in email, sign-in, forms, and dashboard.
- preserve event context through authentication and explain account-email mismatches with a switch-account or support route.
- provide a useful recovery route for expired invitations.

acceptance criteria:

- the invitation prepares the attendee for required materials and the guardian handoff.
- adult attendees are not told they universally need parental consent.
- someone using the wrong account understands why access failed and how to recover.
- the attendee returns to the invited event after authentication.

code references: [attendee invitation](../app/views/participant_mailer/invitation.html.erb), [mailer](../app/mailers/participant_mailer.rb), [invitation processing](../app/controllers/onboarding_controller.rb), [authentication return](../app/controllers/users/omniauth_callbacks_controller.rb).
