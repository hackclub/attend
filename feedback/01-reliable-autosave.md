# make autosave reliable

priority: high. evidence: source review, not a browser reproduction.

the form's save indicator is a promise that an attendee can leave and return without losing their work. the current onboarding endpoint returns `success: true` after calling autosave methods without checking whether their model updates succeeded. file inputs are excluded from browser autosave, and new flight legs are excluded from travel autosave.

someone can therefore see a saved indicator while their latest answers, photo, or new flight details have not persisted.

proposed behavior:

- only show saved when the relevant changes have persisted successfully.
- return actionable field errors when validation prevents saving. preserve the attendee's input.
- distinguish saved text from files and new flight details awaiting an explicit save. ideally make the latter persist safely too.
- make unsaved changes visible before navigation, including navigation using the back link.
- provide a retry action after network failures without requiring the attendee to retype anything.

acceptance criteria:

- invalid updates never produce a successful save indicator.
- reloading after a successful save restores the changes covered by that indicator.
- choosing a photo or adding a flight never implies those changes are saved when they are not.
- a delayed or failed request does not overwrite newer input or leave the attendee uncertain about what persisted.

code references: [onboarding controller](../app/controllers/onboarding_controller.rb), [autosave controller](../app/javascript/controllers/autosave_controller.js), [save indicator](../app/views/onboarding/_autosave_status.html.erb).
