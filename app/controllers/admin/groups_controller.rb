module Admin
  class GroupsController < BaseController
    before_action :require_event_selected
    before_action :require_groups_enabled!
    before_action :authorize_groups!
    before_action :set_group, only: %i[edit update destroy assign unassign]

    def index
      @groups = current_event.groups.ordered
      @member_counts = GroupMembership.where(group: @groups).group(:group_id).count
    end

    def new
      @group = current_event.groups.new
    end

    def create
      @group = current_event.groups.new(group_params)
      @group.position ||= (current_event.groups.maximum(:position) || -1) + 1

      if @group.save
        redirect_to admin_event_groups_path(current_event), notice: "Group created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @members = @group.participant_events.includes(:participant).joins(:participant).order("participants.legal_last_name ASC")
      @available_participants = current_event.participant_events
        .where.not(id: GroupMembership.where(group_id: @group.id).select(:participant_event_id))
        .includes(:participant)
        .joins(:participant)
        .order("participants.legal_last_name ASC")
    end

    def update
      if @group.update(group_params)
        redirect_to admin_event_groups_path(current_event), notice: "Group updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @group.destroy
      redirect_to admin_event_groups_path(current_event), notice: "Group removed."
    end

    def reorder
      ids = Array(params[:ordered_ids])
      current_event.groups.where(id: ids).each do |group|
        group.update_column(:position, ids.index(group.id))
      end
      head :ok
    end

    def assign
      pe_ids = Array(params[:participant_event_ids]).reject(&:blank?)
      valid_ids = current_event.participant_events.where(id: pe_ids).pluck(:id)
      valid_ids.each do |pe_id|
        GroupMembership.find_or_create_by!(group: @group, participant_event_id: pe_id)
      end

      respond_to do |format|
        format.html { redirect_back fallback_location: edit_admin_event_group_path(current_event, @group), notice: "Added #{valid_ids.size} to #{@group.name}." }
        format.json { render json: { added: valid_ids.size } }
      end
    end

    def unassign
      pe_ids = Array(params[:participant_event_ids]).reject(&:blank?)
      GroupMembership.where(group: @group, participant_event_id: pe_ids).destroy_all

      respond_to do |format|
        format.html { redirect_back fallback_location: edit_admin_event_group_path(current_event, @group), notice: "Removed from #{@group.name}." }
        format.json { head :ok }
      end
    end

    private

    def set_group
      @group = current_event.groups.find(params[:id])
    end

    def require_groups_enabled!
      raise ActionController::RoutingError, "Not Found" unless current_event.groups_enabled?
    end

    def authorize_groups!
      authorize current_event, :manage_groups?
    end

    def group_params
      params.require(:group).permit(:name, :slug, :color, :description, :position)
    end
  end
end
