module Admin
  # The invited person's first page in the admin: what the invite is and what
  # setup covers, ahead of the setup wizard (see EventCreationInvite). They
  # aren't an admin of anything yet, so the invite itself is what lets them in.
  class EventCreationInviteOnboardingController < BaseController
    global_page

    def show
    end

    def accept
      @invite.accept!(current_user) if @invite.pending?
      redirect_to admin_new_event_path(invite: @invite.id)
    end

    private

    # The public link explains anything that isn't a usable invite of theirs.
    def authorize_admin_access
      @invite = EventCreationInvite.find_by_token(params[:token])
      return if @invite&.open_to?(current_user)

      redirect_to event_creation_invite_path(params[:token])
    end
  end
end
