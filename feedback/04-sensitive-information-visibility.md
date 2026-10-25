# explain who sees sensitive answers

priority: high. evidence: source review.

the headshot field explains why it is required and who can access it. the health and accommodation pages need similarly specific explanations. the guardian portal displays and allows edits to medical and accessibility answers, but the attendee health page does not explain this sharing.

the accommodation form requires gender identity and conditionally shows roommate gender preferences for nonbinary or transgender attendees. the form needs a visible route for someone who wants to discuss rooming privately with staff.

proposed behavior:

- explain the actual audience for each sensitive section before answers are entered, including guardian visibility where applicable.
- distinguish information visible to guardians, relevant staff, and other attendees. confirm the actual access rules before writing these statements.
- explain why the information is collected and how it affects event support or room assignments.
- offer a private staff conversation for concerns that do not fit the form, and explain who receives that request.
- explain that a submitted accommodation request is recorded, and show when it has been reviewed or confirmed.
- avoid broad confidentiality promises that do not describe the real sharing behavior.

acceptance criteria:

- attendees can understand whether their guardian will see an answer before entering it.
- sensitive rooming concerns have a clear route that does not require disclosure in an unrelated field.
- the product does not describe a requested accommodation as confirmed without an actual confirmation.
- copy is checked against permissions and guardian views, not just the storage implementation.

code references: [profile explanation](../app/views/onboarding/profile.html.erb), [health page](../app/views/onboarding/health.html.erb), [accommodation page](../app/views/onboarding/accommodation.html.erb), [guardian participant information](../app/views/guardian_portal/steps/_participant_info.html.erb).
