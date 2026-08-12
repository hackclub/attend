module Admin
  class SiblingGroupsController < BaseController
    skip_after_action :log_admin_action

    before_action :set_event
    before_action :require_event_selected
    before_action :authorize_rooming!

    def index
      @sibling_groups = SiblingGroup.includes(:participants)
        .joins(participants: :participant_events)
        .where(participant_events: { event_id: @event.id })
        .distinct

      @event_participants = @event.participants.includes(:sibling_groups).order(:legal_last_name, :legal_first_name)
    end

    def create
      participant_ids = params[:participant_ids]

      if participant_ids.blank? || participant_ids.size < 2
        render json: { error: "At least 2 participants required" }, status: :unprocessable_entity
        return
      end

      participants = Participant.where(id: participant_ids)

      sibling_group = SiblingGroup.create!(label: params[:label])
      participants.each do |p|
        sibling_group.sibling_memberships.create!(participant: p)
      end

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append("sibling_groups_list",
            partial: "admin/sibling_groups/sibling_group",
            locals: { sibling_group: sibling_group })
        end
        format.json { render json: sibling_group }
      end
    end

    def update
      sibling_group = SiblingGroup.find(params[:id])
      sibling_group.update!(label: params[:label])

      head :ok
    end

    def destroy
      sibling_group = SiblingGroup.find(params[:id])
      sibling_group.destroy

      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.remove("sibling_group_#{sibling_group.id}") }
        format.json { head :ok }
      end
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def authorize_rooming!
      authorize @event, :manage_rooming?
    end
  end
end
