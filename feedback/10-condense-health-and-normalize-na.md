# condense the health page and handle n/a answers

priority: high. evidence: user-requested improvement and source review. the interaction below is a proposed implementation brief, not existing behavior.

the current health page exposes medical, dietary, learning and cognitive, and accessibility fields at once. someone with nothing to disclose must scan a long form despite every field being optional. repeated allergy-related fields also make it unclear where an answer belongs. placeholder answers such as n/a create noise in reviews and operational data.

the goal is a shorter page with relevant follow-up questions, while retaining useful information and making intentional no-needs answers distinguishable from unanswered questions.

proposed page structure:

- start with compact sections for medical needs, food requirements, and accessibility or support needs.
- offer clear choices such as "nothing to add", "add details", and "prefer to discuss privately" where appropriate. keep unanswered distinct from an explicit nothing-to-add response.
- expand relevant fields when the attendee chooses to add details. existing meaningful answers must automatically open their section when returning.
- explain where to record food allergies versus other allergies, and avoid requiring the same detail twice.
- keep important structured details, including anaphylaxis risk and medication refrigeration, available and clearly labeled.
- lead support questions with what would help the attendee; do not make selecting a diagnosis a prerequisite for requesting support.
- summarize collapsed sections with meaningful answers or an explicit nothing-to-add state, rather than hiding whether they were completed.
- explain guardian visibility before disclosure, consistent with [sensitive information visibility](04-sensitive-information-visibility.md).

proposed n/a handling:

- for optional health-related free-text fields only, treat trimmed, case-insensitive exact answers `n/a`, `na`, and `not applicable` as empty detail values.
- normalize them on explicit save or after leaving the field, with a visible explanation such as "n/a treated as no additional details". do not erase text while the attendee is still typing.
- implement the same normalization on the server so autosave, attendee submission, and guardian edits behave consistently.
- when a saved placeholder is cleared, the persisted value must actually become blank. ignoring the parameter would leave the old value in place.
- preserve an explicit section response separately from the blank detail value. do not infer that someone has no health needs merely because a field is empty.
- do not clear meaningful sentences containing those characters, such as "n/a for medication, but i need step-free access".
- do not automatically classify `no`, `none`, `nil`, dashes, or other ambiguous values as equivalent without an explicit product decision. use the structured nothing-to-add choice for new answers.
- clearing one detail field must not unset risk flags, remove other answers, or mark an entire section as having no needs.
- collapsing a section must never delete its data. if selecting nothing-to-add would replace existing meaningful answers, show the affected answers and require an explicit clear action.
- keep any retrospective cleanup of existing records separate from this form improvement. do not silently rewrite historical disclosures as part of rollout.

acceptance criteria:

- an attendee with nothing to add can complete the page through a few explicit choices without typing n/a into multiple fields.
- existing disclosures remain visible and editable on return.
- ` N/A `, `na`, and `Not Applicable` normalize to blank optional detail values after save and stay blank on reload.
- meaningful sentences are retained verbatim apart from any separately agreed whitespace handling.
- clearing a previously stored placeholder updates the database rather than retaining stale text.
- autosave accurately reports whether normalization and persistence succeeded.
- attendee and guardian entry paths produce the same result.
- unanswered, nothing to add, privately discussing, and disclosed needs remain distinguishable in summaries. blank answers are not automatically presented as a confirmed absence of a condition.
- condensation preserves relevant details for staff and does not hide anaphylaxis or other recorded requirements.

code references: [health form](../app/views/onboarding/health.html.erb), [health save and autosave](../app/controllers/onboarding_controller.rb), [guardian participant information](../app/views/guardian_portal/steps/_participant_info.html.erb), [review summary](../app/views/onboarding/review.html.erb), [event dashboard](../app/views/dashboard/show.html.erb).
