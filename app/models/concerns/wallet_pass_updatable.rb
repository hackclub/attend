module WalletPassUpdatable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_wallet_pass_update, on: [ :update ]
  end

  private

  def enqueue_wallet_pass_update
    return unless wallet_pass_relevant_change?

    # Bulk enqueue: an Event update fans out to every participant_event, and
    # one perform_later per pass meant hundreds of sequential queue-db
    # round-trips inside the request's commit path
    jobs = participant_events_to_update.map { |pe| WalletPassUpdateJob.new(pe.id) }
    ActiveJob.perform_all_later(jobs)
  end

  # Override with a saved_changes check when only some of the model's
  # attributes appear on the pass (see Participant). Defaults to true so a
  # model without an allowlist never misses a pass refresh.
  def wallet_pass_relevant_change?
    true
  end

  def participant_events_to_update
    raise NotImplementedError, "Subclasses must implement #participant_events_to_update"
  end
end
