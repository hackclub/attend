namespace :stuck_completions do
  desc <<~DESC
    Complete participants whose db status never caught up with reality.

    `OnboardingController#complete` used to set minors to `awaiting_guardian`
    and stop there. If the guardian signed the waiver and finished the portal
    *before* the participant hit submit, every `mark_complete_if_eligible!`
    hook had already run and bailed on the missing code of conduct — and the
    submit itself never re-checked. Those rows sit at `awaiting_guardian`
    forever: `display_status` says "Complete", but the dashboard hides the
    boarding pass / QR because it gates on the raw `complete?` enum.

    Fixed at the source in `OnboardingController#complete`; this repairs the
    rows already stuck. Completion here is a pure status flip — ParticipantEvent
    has no status callbacks, so no mail or webhook fires.

    ENV:
      EVENT=<slug>   only this event (default: every event)
      ALL_EVENTS=1   include events that have already ended (default: skip)
      APPLY=1        actually write (default: dry run)
  DESC
  task repair: :environment do
    apply = ENV["APPLY"] == "1"

    scope = ParticipantEvent
      .where(status: [ :invited, :in_progress, :awaiting_guardian ])
      .includes(:event, :participant, :consents, :guardian_participant_events)

    if ENV["EVENT"].present?
      scope = scope.where(event: Event.find_by!(slug: ENV.fetch("EVENT")))
    elsif ENV["ALL_EVENTS"] != "1"
      scope = scope.joins(:event).where("events.ends_at IS NULL OR events.ends_at >= ?", Time.current)
    end

    # eligible_for_completion? walks consents/guardians/custom documents, so it
    # can't be pushed into SQL — filter in Ruby off the preloaded association.
    stuck = scope.select(&:eligible_for_completion?)

    puts "#{stuck.size} stuck participant#{'s' unless stuck.size == 1} (apply=#{apply}):"
    stuck.group_by { |pe| pe.event }.sort_by { |event, _| event.slug }.each do |event, rows|
      puts "  #{event.slug} (#{rows.size}):"
      rows.each { |pe| puts "    - #{pe.participant.email} [#{pe.status}] #{pe.id}" }
    end

    unless apply
      puts "Dry run — set APPLY=1 to write."
      exit
    end

    PaperTrail.request.whodunnit = "rake stuck_completions:repair"

    completed = stuck.count { |pe| pe.mark_complete_if_eligible! }
    puts "Completed #{completed} of #{stuck.size}."
  end
end
