# make it clear that the qr code is the entry ticket

priority: high. evidence: user-reported attendee confusion, supported by the source review of the pass presentation.

attendees did not understand that their qr code was their entry ticket. the current presentation uses boarding pass, passenger, airport codes, and flight imagery. although it includes scan-to-check-in instructions, the surrounding travel metaphor can obscure what the attendee actually needs to show at the event.

proposed behavior:

- label the primary artifact "your event entry ticket" and put the event name beside it.
- place a direct instruction immediately beside the qr code: "show this qr code to staff when you arrive. this is your ticket into [event]."
- use the same ticket terminology in registration confirmation, dashboard, wallet actions, pdf, and pre-event reminders.
- explain that this ticket is for event entry if flight-related language remains elsewhere.
- make saving the ticket to a wallet or downloading it a clear next action when registration becomes confirmed.
- make the ticket reachable through an obvious view-ticket action, with the qr code prominent on a phone.
- when registration is incomplete, explain why the ticket is not yet available and link to the remaining tasks.
- after check-in, show a clear checked-in state without hiding information attendees still need.

suggested copy:

> your registration is confirmed. this qr code is your entry ticket. save it now and show it to staff at check-in.

acceptance criteria:

- an attendee shown the confirmed dashboard can identify what to present at the entrance without prompting.
- the qr code has an explicit event-entry instruction rather than relying on the visual metaphor.
- wallet and pdf options are presented as ways to save the same entry ticket.
- the pass remains scannable across supported themes and phone layouts.
- incomplete registration states explain the blockers without displaying a misleading confirmed ticket.

code references: [ticket presentation](../app/views/dashboard/show.html.erb), [dashboard summary](../app/views/dashboard/index.html.erb), [apple wallet ticket](../app/lib/passkit/event_ticket.rb), [google wallet ticket](../app/lib/google_wallet/event_ticket.rb).
