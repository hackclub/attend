class ApplicationController < ActionController::Base
  include Pundit::Authorization

  IMPERSONATION_TIMEOUT = 1.hour

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :reset_query_counter
  before_action :check_maintenance_mode
  before_action :check_impersonation_timeout
  before_action :set_current_attributes
  before_action :set_paper_trail_whodunnit

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_invalid_authenticity_token
  rescue_from ActiveRecord::RecordNotFound, with: :handle_record_not_found

  helper_method :current_event, :impersonating?, :impersonator

  def current_event
    return @current_event if defined?(@current_event)

    @current_event = Event.find_by(id: session[:current_event_id])
  end

  def set_current_event(event)
    session[:current_event_id] = event&.id
    Current.event = event
    @current_event = event
  end

  private

  def set_current_attributes
    Current.user = current_user if respond_to?(:current_user, true)
    Current.event = current_event
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
  end

  def user_for_paper_trail
    Current.user&.id
  end

  def require_event_selected
    unless current_event
      redirect_to root_path, alert: "Please select an event first."
    end
  end

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back(fallback_location: root_path)
  end

  def handle_invalid_authenticity_token
    flash[:alert] = "Your session has expired. Please try again."
    redirect_back(fallback_location: root_path)
  end

  def handle_record_not_found
    flash[:alert] = "The record you were looking for could not be found. It may have been removed."
    redirect_back(fallback_location: root_path)
  end

  def find_current_auditor
    current_user if current_user&.global_admin?
  end

  def impersonating?
    session[:impersonator_user_id].present?
  end

  def impersonator
    @impersonator ||= User.find_by(id: session[:impersonator_user_id])
  end

  def check_impersonation_timeout
    return unless impersonating?
    # Skip during impersonation management actions
    return if self.class.name.include?("ImpersonationsController")

    started_at = session[:impersonation_started_at]
    timeout = IMPERSONATION_TIMEOUT

    if started_at.blank? || Time.at(started_at) < timeout.ago
      impersonator_user = impersonator
      impersonated_user_id = current_user&.id

      Rails.logger.warn("[Security] Impersonation expired: admin=#{impersonator_user&.id} target=#{impersonated_user_id} ip=#{request.remote_ip}")

      session.delete(:impersonator_user_id)
      session.delete(:impersonation_started_at)

      if impersonator_user&.global_admin?
        sign_in(:user, impersonator_user)
        flash[:alert] = "Your impersonation session has expired."
      else
        sign_out(:user)
        flash[:alert] = "Your session has expired. Please sign in again."
      end

      redirect_to root_path and return
    end
  end

  def check_maintenance_mode
    return unless Setting.maintenance_mode?
    return if admin_controller?
    return if current_user&.admin?

    render "home/maintenance", layout: "application", status: :service_unavailable
  end

  def admin_controller?
    self.class.module_parent == Admin || is_a?(Admin::BaseController)
  end

  def reset_query_counter
    QueryCounter.reset!
  end
end
