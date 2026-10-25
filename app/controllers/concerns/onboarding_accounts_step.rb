# The onboarding "accounts" step: link GitHub and/or itch.io when the event's
# series asks for them (EventSeries#github_linking / #itch_linking). Linking
# itself happens in ConnectedAccountsController; this step only shows the
# state and holds Continue until required accounts are connected.
module OnboardingAccountsStep
  extend ActiveSupport::Concern

  ACCOUNTS_STEP = "accounts"

  private

  def load_accounts_step_data
    @connected_accounts = @participant_event.participant.connected_accounts.index_by(&:provider)
    @account_modes = current_event.linked_account_providers.index_with { |provider| current_event.account_linking_mode(provider) }
  end

  def save_accounts_step
    load_accounts_step_data
    missing = missing_required_accounts
    return true if missing.empty?

    flash.now[:alert] = "Please connect your #{missing.map { |provider| AccountLinking.provider_name(provider) }.to_sentence} account to continue."
    false
  end

  # Re-checked on submit too: turning linking on mid-registration doesn't
  # move anyone's saved step index back onto this step. A provider without
  # OAuth credentials can't be connected, so it never blocks anyone.
  def missing_required_accounts
    required = current_event.required_account_providers.select { |provider| AccountLinking.available?(provider) }
    return [] if required.empty?

    required - @participant_event.participant.connected_accounts.pluck(:provider)
  end
end
