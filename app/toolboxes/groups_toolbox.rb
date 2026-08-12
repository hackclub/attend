class GroupsToolbox < ApplicationToolbox
  tool "List an event's groups with member counts.", access: :read, scope: "groups:read" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
  end
  def index
    require_event!
    authorize! current_event, :show?
    render json: {
      event: current_event.name,
      groups: current_event.groups.ordered.map { |g| serialize_group(g) }
    }
  end

  tool "Show one group and its members.", access: :read, scope: "groups:read" do
    param :group_id, :string, "Group ID"
  end
  def show
    @group = find_group!
    authorize! @group.event, :show?
    render json: serialize_group(@group, members: true)
  end

  tool "Create a group in an event.", access: :write, scope: "groups:write" do
    param :event_id, :string, "Event ID", optional: true
    param :event_slug, :string, "Event slug", optional: true
    param :name, :string, "Group name"
    param :description, :string, "Description", optional: true
    param :color, :string, "Hex color, e.g. #ff8c37", optional: true
  end
  def create
    require_event!
    authorize! current_event, :manage_groups?
    @group = current_event.groups.create!(params.permit(:name, :description, :color).to_h)
    render json: serialize_group(@group, members: true)
  end

  tool "Add a participant registration to a group.", access: :write, scope: "groups:write" do
    param :group_id, :string, "Group ID"
    param :participant_event_id, :string, "ParticipantEvent ID to add"
  end
  def add_member
    @group = find_group!
    authorize! @group.event, :manage_groups?
    pe = @group.event.participant_events.find(params[:participant_event_id])
    @group.group_memberships.find_or_create_by!(participant_event: pe)
    render json: serialize_group(@group, members: true)
  end

  tool "Remove a participant registration from a group.", access: :write, scope: "groups:write" do
    param :group_id, :string, "Group ID"
    param :participant_event_id, :string, "ParticipantEvent ID to remove"
  end
  def remove_member
    @group = find_group!
    authorize! @group.event, :manage_groups?
    @group.group_memberships.find_by(participant_event_id: params[:participant_event_id])&.destroy!
    render json: serialize_group(@group, members: true)
  end

  private

  def find_group!
    Group.find(params[:group_id]).tap do |g|
      halt error: "You don't have access to that event." unless current_user.can_access_event?(g.event)
    end
  end

  def serialize_group(g, members: false)
    data = { id: g.id, name: g.name, slug: g.slug, color: g.color,
             description: g.description, member_count: g.group_memberships.count }
    return data unless members

    data.merge(members: g.participant_events.includes(:participant).map { |pe|
      { participant_event_id: pe.id,
        name: [ pe.participant.preferred_name.presence || pe.participant.legal_first_name,
                pe.participant.legal_last_name ].join(" ") }
    })
  end
end
