module WalletPassUpdatable
  extend ActiveSupport::Concern

  included do
    after_commit :enqueue_wallet_pass_update, on: [ :update ]
  end

  private

  def enqueue_wallet_pass_update
    participant_events_to_update.each do |pe|
      WalletPassUpdateJob.perform_later(pe.id)
    end
  end

  def participant_events_to_update
    raise NotImplementedError, "Subclasses must implement #participant_events_to_update"
  end
end
