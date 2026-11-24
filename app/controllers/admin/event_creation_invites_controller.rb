module Admin
  # Global admins invite someone to create an event and set it up themselves
  # (see EventCreationInvite), and keep track of who has.
  class EventCreationInvitesController < BaseController
    global_page
    before_action :require_global_admin
    before_action :set_invite, only: [ :resend, :revoke ]

    def index
      @invites = EventCreationInvite.includes(:invited_by, :event_series, :event).order(created_at: :desc).limit(200)
    end

    def new
      @invite = EventCreationInvite.new(event_series: EventSeries.find_by(slug: params[:series]))
    end

    def create
      @invite = EventCreationInvite.new(invite_params)
      @invite.invited_by = current_user

      if @invite.save
        @invite.deliver_later
        redirect_to admin_event_creation_invites_path, notice: "Invite sent to #{@invite.email}."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def resend
      unless @invite.pending? || @invite.expired?
        redirect_to admin_event_creation_invites_path, alert: "Only an invite that hasn't been accepted can be sent again."
        return
      end

      @invite.resend!
      redirect_to admin_event_creation_invites_path, notice: "Invite sent again to #{@invite.email}. Earlier links no longer work."
    end

    def revoke
      if @invite.completed?
        redirect_to admin_event_creation_invites_path, alert: "This invite has already been used to create an event."
        return
      end

      @invite.revoke!
      redirect_to admin_event_creation_invites_path, notice: "Invite for #{@invite.email} revoked."
    end

    private

    def set_invite
      @invite = EventCreationInvite.find(params[:id])
    end

    def invite_params
      params.require(:event_creation_invite).permit(:email, :event_series_id, :note)
    end

    def require_global_admin
      return if current_user&.global_admin?

      redirect_to admin_root_path, alert: "You must be a global admin to invite people to create events."
    end
  end
end
