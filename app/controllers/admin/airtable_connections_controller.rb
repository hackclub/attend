# Connects an event's Airtable sync with OAuth instead of a pasted personal
# access token. Airtable only redirects to a pre-registered URI, so the
# callback is one fixed route and the event rides along in the session with
# the state and PKCE verifier, for one round trip.
class Admin::AirtableConnectionsController < Admin::BaseController
  STATE_TTL = 10.minutes

  skip_before_action :set_current_event_from_session
  # The callback is a GET, which the generic logger skips, and the start of
  # the flow changes nothing; both ends log explicitly instead.
  skip_after_action :log_admin_action

  def create
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :manage_integrations?
    set_current_event(@event)

    unless oauth.configured?
      redirect_to admin_event_integrations_path(@event), alert: "Connecting Airtable isn't set up on this server yet."
      return
    end

    verifier = SecureRandom.urlsafe_base64(64)
    state = SecureRandom.urlsafe_base64(32)
    session[:airtable_oauth] = {
      "event_id" => @event.id,
      "state" => state,
      "verifier" => verifier,
      "issued_at" => Time.current.to_i
    }

    redirect_to oauth.authorize_url(
      state: state,
      redirect_uri: admin_airtable_oauth_callback_url,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    ), allow_other_host: true
  end

  def callback
    link = session.delete(:airtable_oauth)
    @event = Event.find_by(id: link["event_id"]) if link.is_a?(Hash)

    unless @event && valid_link?(link)
      redirect_to(@event ? admin_event_integrations_path(@event) : admin_root_path,
        alert: "That Airtable sign-in expired. Please try connecting again.")
      return
    end

    authorize @event, :manage_integrations?
    set_current_event(@event)

    if params[:error].present?
      detail = params[:error_description].presence || params[:error]
      redirect_to admin_event_integrations_path(@event), alert: "Airtable wasn't connected: #{detail}"
      return
    end

    connection = save_connection(oauth.exchange_code(
      code: params[:code].to_s,
      redirect_uri: admin_airtable_oauth_callback_url,
      code_verifier: link["verifier"]
    ))
    log_audit("connect_airtable", connection)

    redirect_to admin_event_integrations_path(@event), notice: connected_notice(connection)
  rescue Airtable::Error => e
    Rails.logger.warn("[AirtableOauth] Connecting event #{@event&.id} failed: #{e.message}")
    redirect_to admin_event_integrations_path(@event), alert: "We couldn't connect Airtable. #{e.message}"
  end

  def destroy
    @event = Event.find_by!(slug: params[:slug])
    authorize @event, :manage_integrations?
    set_current_event(@event)

    if (connection = @event.airtable_connection)
      connection.destroy!
      log_audit("disconnect_airtable", connection)
    end

    # Airtable has no revocation endpoint; the grant lives on until the
    # refresh token lapses or the organiser removes it in their account.
    redirect_to admin_event_integrations_path(@event),
      notice: "Airtable disconnected. To revoke Attend's access fully, remove it under Integrations in your Airtable account."
  end

  private

  def oauth
    @oauth ||= Airtable::Oauth.new
  end

  def valid_link?(link)
    link["issued_at"].to_i > STATE_TTL.ago.to_i &&
      params[:state].present? &&
      ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, link["state"].to_s)
  end

  def save_connection(token)
    # Both are nice-to-haves for the integrations page; a failure here must
    # not throw away a grant the organiser just approved.
    profile = best_effort({}) { oauth.whoami(token.access_token) }
    bases = best_effort([]) { oauth.list_bases(token.access_token) }

    connection = @event.airtable_connection || @event.build_airtable_connection
    connection.update!(AirtableConnection.attributes_from_token(token).merge(
      connected_by: current_user,
      airtable_user_id: profile["id"],
      airtable_email: profile["email"],
      bases: bases
    ))

    # The connection replaces any pasted token, and whoever connected is who
    # hears about it if the sync later pauses or keeps failing.
    updates = { airtable_api_key: nil, airtable_config_updated_by_id: current_user.id }
    # A connected event syncs through the records API into a table of its
    # own; the old Sync API table is externally synced and can't be written.
    if @event.airtable_sync_source_id.present?
      updates.merge!(airtable_sync_source_id: nil, airtable_sync_table_id: nil)
    end
    @event.update_columns(updates)
    if @event.airtable_base_id.blank? && bases.one?
      @event.update_columns(config: @event.config.merge("airtable_base_id" => bases.first["id"]))
    end
    @event.resume_airtable_sync!
    AirtableJobs::SyncAllJob.perform_later(@event.id) if @event.airtable_sync_configured?

    connection
  end

  def best_effort(fallback)
    yield
  rescue Airtable::Error => e
    Rails.logger.warn("[AirtableOauth] #{e.message}")
    fallback
  end

  def connected_notice(connection)
    as = connection.account_label.present? ? " as #{connection.account_label}" : ""
    if @event.airtable_sync_configured?
      "Airtable connected#{as}. Sync started."
    else
      "Airtable connected#{as}. Choose a base below to start syncing."
    end
  end

  def log_audit(action, connection)
    AuditLog.log!(
      action: action,
      record: connection,
      actor: current_user,
      event: @event,
      changed_fields: connection.destroyed? ? {} : { "scope" => connection.scope, "base_ids" => connection.bases.pluck("id") },
      metadata: { ip: request.remote_ip, user_agent: request.user_agent, controller: controller_name }
    )
  rescue StandardError => e
    Rails.logger.error("[Security] Failed to create audit log: #{e.class} - #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    raise if Rails.env.local?
  end
end
