# Where the link in an event creation invite lands (see EventCreationInvite).
# Everything the invited person does happens in the admin; this is the way
# in: sign-in for someone signed out, and the pages for a link that can't be
# used (expired, withdrawn, someone else's).
class EventCreationInvitesController < ApplicationController
  def show
    @invite = EventCreationInvite.find_by_token(params[:token])
    return render :unavailable, status: :not_found unless @invite
    return render :unavailable if @invite.revoked? || @invite.expired?

    unless user_signed_in?
      # Sign-in comes back here (OmniauthCallbacksController#after_sign_in_path).
      store_location_for(:user, event_creation_invite_path(params[:token]))
      return render :sign_in
    end

    if @invite.open_to?(current_user)
      redirect_to admin_event_creation_invite_welcome_path(params[:token])
    elsif @invite.completed? && @invite.accepted_by_id == current_user.id
      event = @invite.event
      return render :unavailable unless event

      redirect_to event.setup_complete? ? admin_event_dashboard_path(event) : admin_event_setup_path(event)
    else
      render :wrong_account
    end
  end
end
