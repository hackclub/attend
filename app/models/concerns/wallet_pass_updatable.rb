module WalletPassUpdatable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_wallet_pass_update, on: [ :update ]
  end

  private

  def enqueue_wallet_pass_update
    # Bulk enqueue: an Event update fans out to every participant_event, and
    # one perform_later per pass meant hundreds of sequential queue-db
    # round-trips inside the request's commit path
    jobs = participant_events_to_update.map { |pe| WalletPassUpdateJob.new(pe.id) }
    ActiveJob.perform_all_later(jobs)
  end

  def participant_events_to_update
    raise NotImplementedError, "Subclasses must implement #participant_events_to_update"
  end
end
