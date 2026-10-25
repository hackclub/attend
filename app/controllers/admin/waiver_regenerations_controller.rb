module Admin
  # Offered from the waiver-dates banner once an event's dates move after
  # waivers went out: re-clones the event's default templates with the new
  # dates, then re-issues the waivers people already have.
  class WaiverRegenerationsController < BaseController
    SCOPES = %w[everyone unsigned].freeze
    ALREADY_RUNNING_NOTICE = "Waivers for this event are already being regenerated.".freeze

    before_action :set_event

    def new
      unless @event.waiver_dates_stale?
        redirect_to admin_event_dashboard_path(@event), notice: "This event's waivers already show its current dates."
        return
      end

      @templates = regeneration.templates
      @unsigned_count = regeneration.people_count(include_signed: false)
      @everyone_count = regeneration.people_count(include_signed: true)
      @blocked = regeneration.blocked?
    end

    def create
      scope = params[:scope].to_s
      unless SCOPES.include?(scope)
        redirect_to new_admin_event_waiver_regeneration_path(@event), alert: "Choose who should get a new waiver."
        return
      end
      include_signed = scope == "everyone"

      # Cheap early exit for a resubmit, before asking DocuSeal anything. The
      # atomic claim below still settles two requests arriving together.
      unless @event.waiver_dates_stale?
        redirect_to admin_event_dashboard_path(@event), notice: ALREADY_RUNNING_NOTICE
        return
      end

      # Without knowing which templates Attend created we'd re-issue waivers
      # that still show the old dates, so stop before claiming anything.
      if regeneration.blocked?
        redirect_to new_admin_event_waiver_regeneration_path(@event),
          alert: "DocuSeal didn't respond, so Attend couldn't check the waiver templates. Nothing was sent — try again in a moment."
        return
      end

      flagged_since = @event.waiver_dates_stale_since

      # Claim the regeneration by clearing the flag in one statement, so a
      # double-submit (or two admins at once) can't re-issue — and email —
      # everyone twice.
      claimed = Event.where(id: @event.id, waiver_dates_stale_since: flagged_since)
        .where.not(waiver_dates_stale_since: nil)
        .update_all(waiver_dates_stale_since: nil) == 1
      unless claimed
        redirect_to admin_event_dashboard_path(@event), notice: ALREADY_RUNNING_NOTICE
        return
      end

      enqueued = false
      begin
        regeneration.regenerate_templates!
        count = regeneration.people_count(include_signed: include_signed)
        RegenerateWaiversForDateChangeJob.perform_later(@event.id, include_signed: include_signed)
        enqueued = true
      rescue Docuseal::Error, ArgumentError, Faraday::Error => e
        redirect_to new_admin_event_waiver_regeneration_path(@event),
          alert: "Couldn't update the waiver templates on DocuSeal: #{e.message}. Nothing was sent — try again in a moment."
        return
      ensure
        # Anything short of the job being enqueued (including errors we
        # don't expect, which still propagate) puts the warning back, so the
        # banner keeps offering a retry instead of vanishing for good.
        restore_stale_flag(flagged_since) unless enqueued
      end

      redirect_to admin_event_dashboard_path(@event), notice: created_notice(count)
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
      authorize @event, :regenerate_waivers?
      set_current_event(@event)
    end

    def regeneration
      @regeneration ||= Docuseal::WaiverDateRegeneration.new(@event)
    end

    # Only refills an empty flag: if the dates moved again meanwhile, the
    # newer timestamp is the one to keep.
    def restore_stale_flag(flagged_since)
      Event.where(id: @event.id, waiver_dates_stale_since: nil).update_all(waiver_dates_stale_since: flagged_since)
    end

    def created_notice(count)
      regenerated = regeneration.templates.select(&:regenerable?).map { |t| t.label.downcase }
      parts = []
      parts << "The #{regenerated.to_sentence} now #{regenerated.one? ? "shows" : "show"} #{@event.formatted_date_range}." if regenerated.any?
      parts << if count.zero?
        "No one needed a new waiver."
      else
        "Sending new waivers to #{helpers.pluralize(count, "participant")}. They'll be emailed shortly."
      end
      parts.join(" ")
    end
  end
end
