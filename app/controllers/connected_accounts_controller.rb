# Links a participant's GitHub or itch.io account, from the onboarding
# accounts step (when an event asks for one) or the Connections section of
# the profile page. Both providers use the
# authorization code flow with PKCE; the state, verifier and return path
# live in the session for one round trip.
class ConnectedAccountsController < ApplicationController
  include RestrictsBannedUsers
  STATE_TTL = 10.minutes
  RETURN_PREFIXES = %w[/onboarding /dashboard].freeze

  before_action :authenticate_user!
  before_action :load_participant
  before_action :load_client

  def create
    unless @client.configured?
      redirect_to return_path, alert: "#{provider_name} linking isn't set up yet. Please try again later."
      return
    end

    verifier = SecureRandom.urlsafe_base64(64)
    state = SecureRandom.urlsafe_base64(32)
    session[:account_link] = {
      "provider" => provider,
      "state" => state,
      "verifier" => verifier,
      "participant_id" => @participant.id,
      "return_to" => return_path,
      "issued_at" => Time.current.to_i
    }

    redirect_to @client.authorize_url(
      state: state,
      redirect_uri: connected_account_callback_url(provider: provider),
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    ), allow_other_host: true
  end

  def callback
    link = session.delete(:account_link)
    return_to = link.is_a?(Hash) ? link["return_to"] : dashboard_path

    unless valid_link?(link)
      redirect_to return_to, alert: "That #{provider_name} sign-in link expired. Please try connecting again."
      return
    end

    if params[:error].present?
      redirect_to return_to, alert: "#{provider_name} wasn't connected."
      return
    end

    token = @client.exchange_code(
      code: params[:code].to_s,
      redirect_uri: connected_account_callback_url(provider: provider),
      code_verifier: link["verifier"]
    )
    profile = @client.fetch_profile(token[:access_token])

    account = @participant.connected_accounts.find_or_initialize_by(provider: provider)
    account.update!(
      uid: profile[:uid],
      username: profile[:username],
      profile: profile[:profile],
      access_token: token[:access_token],
      scope: token[:scope],
      connected_at: Time.current
    )
    fill_public_profile_github(account)

    redirect_to return_to, notice: "#{provider_name} connected as #{account.username}."
  rescue AccountLinking::Error => e
    Rails.logger.warn("[ConnectedAccounts] #{provider} link failed: #{e.message}")
    redirect_to return_to, alert: "We couldn't connect your #{provider_name} account. Please try again."
  end

  def destroy
    account = @participant.connected_accounts.find_by(provider: provider)

    if account
      revoke(account)
      account.destroy!
    end

    redirect_to return_path, notice: "#{provider_name} disconnected."
  end

  private

  def provider
    params[:provider]
  end

  def provider_name
    AccountLinking.provider_name(provider)
  end

  def load_participant
    @participant = current_user.participant
    redirect_to dashboard_path, alert: "Start your registration before connecting accounts." unless @participant
  end

  def load_client
    @client = AccountLinking.client_for(provider)
  end

  def valid_link?(link)
    link.is_a?(Hash) &&
      link["provider"] == provider &&
      link["participant_id"] == @participant.id &&
      link["issued_at"].to_i > STATE_TTL.ago.to_i &&
      params[:state].present? &&
      ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, link["state"].to_s)
  end

  # Only paths back into onboarding or the dashboard, never another host.
  def return_path
    path = params[:return_to].to_s
    return dashboard_path unless path.start_with?(*RETURN_PREFIXES) && !path.start_with?("//")

    uri = URI.parse(path)
    uri.host.nil? && uri.scheme.nil? ? path : dashboard_path
  rescue URI::InvalidURIError
    dashboard_path
  end

  def fill_public_profile_github(account)
    return unless account.github? && @participant.public_profile_github.blank?

    @participant.public_profile_github = account.username
    @participant.save(validate: false)
  end

  # Best effort: the link is removed on our side whether or not the provider
  # accepts the revocation.
  def revoke(account)
    @client.revoke(account.access_token)
  rescue StandardError => e
    Rails.logger.warn("[ConnectedAccounts] #{provider} revoke failed: #{e.message}")
  end
end
