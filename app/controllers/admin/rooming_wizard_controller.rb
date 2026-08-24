module Admin
  class RoomingWizardController < BaseController
    skip_after_action :log_admin_action

    before_action :set_event
    before_action :require_event_selected
    before_action :authorize_rooming!
    before_action :set_rooming_plan
    before_action :require_unlocked!, only: %i[manual_assign auto_assign move_assignment create_room update_room destroy_room add_staff remove_staff toggle_exempt reorder_rooms]

    def show
      redirect_to latest_wizard_step_path
    end

    def setup
      @participant_stats = calculate_participant_stats
      @suggested_siblings = find_suggested_siblings
    end

    def create_setup
      configurations = (params[:room_configurations] || []).filter_map do |config|
        capacity = config[:capacity].to_i
        count = config[:count].to_i
        next if capacity < 1 || count < 1
        { capacity: capacity, count: count }
      end

      if configurations.empty?
        redirect_to setup_admin_event_rooming_wizard_path(@event.slug), alert: "Please add at least one room configuration"
        return
      end

      default_capacity = configurations.first[:capacity]

      ActiveRecord::Base.transaction do
        @rooming_plan.update!(room_capacity: default_capacity, status: :draft)

        empty_rooms = @event.rooms
          .participant_rooms
          .left_joins(:room_assignments)
          .where(room_assignments: { id: nil })
          .where(staff_names: [ nil, "" ])
          .where(name: nil, notes: nil)

        existing_by_capacity = empty_rooms.group_by(&:capacity)

        configurations.each do |config|
          available = existing_by_capacity[config[:capacity]] || []
          reused = available.shift(config[:count])
          existing_by_capacity[config[:capacity]] = available

          (config[:count] - reused.size).times do
            @event.rooms.create!(capacity: config[:capacity])
          end
        end

        existing_by_capacity.values.flatten.each(&:destroy)
      end

      redirect_to preferences_admin_event_rooming_wizard_path(@event.slug), notice: "Room setup saved"
    end

    def preferences
      @participant_events = scope_to_group(@event.participant_events)
        .includes(:event, :participant, :accommodation,
          roommate_preferences: { preferred_participant_event: :participant },
          roommate_exclusions: { excluded_participant_event: :participant })
        .where(status: %w[complete in_progress])
        .joins(:accommodation)
        .order("participants.legal_last_name ASC")

      @unreviewed_count = @participant_events.joins(:accommodation).where(accommodations: { roommate_links_reviewed: false }).count
    end

    def link_preference
      participant_event = @event.participant_events.find(params[:participant_event_id])
      target_pe = @event.participant_events.find(params[:target_participant_event_id])
      kind = params[:kind]
      rank = params[:rank]

      if kind == "preference"
        RoommatePreference.find_or_create_by!(
          participant_event: participant_event,
          preferred_participant_event: target_pe
        ) do |pref|
          pref.rank = rank
          pref.admin_confirmed = true
        end
      else
        RoommateExclusion.find_or_create_by!(
          participant_event: participant_event,
          excluded_participant_event: target_pe
        ) do |excl|
          excl.admin_confirmed = true
        end
      end

      participant_event.accommodation&.update!(roommate_links_reviewed: true)

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "preference_links_#{participant_event.id}",
            partial: "admin/rooming_wizard/preference_links",
            locals: { participant_event: participant_event }
          )
        end
        format.html { redirect_to preferences_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def unlink_preference
      kind = params[:kind]

      if kind == "preference"
        RoommatePreference.find(params[:link_id]).destroy
      else
        RoommateExclusion.find(params[:link_id]).destroy
      end

      head :ok
    end

    def auto_assign
      result = Rooming::AutoAssignService.new(@event, group: selected_group).call

      @rooming_plan.update!(status: :auto_assigned)

      redirect_to assignments_admin_event_rooming_wizard_path(@event.slug),
        notice: "Auto-assignment complete. #{result[:assigned]} participants assigned, #{result[:unassigned]} unassigned."
    end

    def manual_assign
      @rooming_plan.update!(status: :preferences_linked)

      redirect_to assignments_admin_event_rooming_wizard_path(@event.slug),
        notice: "Manual assignment ready. Drag participants into rooms to assign them."
    end

    def assignments
      load_assignments_data
    end

    def move_assignment
      participant_event = @event.participant_events.find(params[:participant_event_id])
      room_id = params[:room_id]

      participant_event.room_assignment&.destroy

      if room_id.present?
        room = @event.rooms.find(room_id)

        if room.has_staff?
          render json: { error: "Cannot assign participants to rooms with staff" }, status: :unprocessable_entity
          return
        end

        if !room.can_add_participants?
          render json: { error: "Room is full" }, status: :unprocessable_entity
          return
        end

        flags = calculate_assignment_flags(participant_event, room)
        RoomAssignment.create!(
          room: room,
          participant_event: participant_event,
          flags: flags
        )
      end

      load_assignments_data

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("summary_bar", partial: "admin/rooming_wizard/summary_bar"),
            turbo_stream.replace("unassigned_sidebar", partial: "admin/rooming_wizard/unassigned_sidebar"),
            turbo_stream.replace("rooms_container", partial: "admin/rooming_wizard/rooms_container")
          ]
        end
        format.json { head :ok }
      end
    end

    def create_room
      room = @event.rooms.create!(
        capacity: params[:capacity] || @rooming_plan.room_capacity,
        staff_only: params[:staff_only] == "true",
        name: params[:name].presence,
        notes: params[:notes].presence
      )

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.append("rooms_list", partial: "admin/rooming_wizard/room_card", locals: { room: room })
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def update_room
      room = @event.rooms.find(params[:room_id])
      room.update!(room_params)

      load_assignments_data

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("summary_bar", partial: "admin/rooming_wizard/summary_bar"),
            turbo_stream.replace("room_#{room.id}", partial: "admin/rooming_wizard/room_card", locals: { room: room })
          ]
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def add_staff
      room = @event.rooms.find(params[:room_id])
      staff_name = params[:staff_name]&.strip

      if staff_name.blank?
        render json: { error: "Staff name is required" }, status: :unprocessable_entity
        return
      end

      if room.has_participants?
        render json: { error: "Cannot add staff to room with participants" }, status: :unprocessable_entity
        return
      end

      if !room.can_add_staff? && room.staff_names.blank?
        render json: { error: "Room is full" }, status: :unprocessable_entity
        return
      end

      current_staff = room.staff_names_list
      current_staff << staff_name
      room.update!(staff_names: current_staff.join(", "))

      load_assignments_data

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("summary_bar", partial: "admin/rooming_wizard/summary_bar"),
            turbo_stream.replace("room_#{room.id}", partial: "admin/rooming_wizard/room_card", locals: { room: room })
          ]
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def remove_staff
      room = @event.rooms.find(params[:room_id])
      staff_name = params[:staff_name]

      current_staff = room.staff_names_list
      current_staff.delete(staff_name)
      room.update!(staff_names: current_staff.join(", "))

      load_assignments_data

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("summary_bar", partial: "admin/rooming_wizard/summary_bar"),
            turbo_stream.replace("room_#{room.id}", partial: "admin/rooming_wizard/room_card", locals: { room: room })
          ]
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def destroy_room
      room = @event.rooms.find(params[:room_id])

      room.room_assignments.each do |assignment|
        assignment.destroy
      end

      room.destroy

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.remove("room_#{room.id}")
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def reorder_rooms
      ids = Array(params[:room_ids])

      ActiveRecord::Base.transaction do
        ids.each_with_index do |id, index|
          @event.rooms.where(id: id).update_all(position: index)
        end
      end

      head :ok
    end

    def acknowledge_trans_nb
      assignment = RoomAssignment.joins(room: :event).where(events: { id: @event.id }).find(params[:assignment_id])
      assignment.update!(trans_nb_acknowledged: true)

      head :ok
    end

    def toggle_exempt
      participant_event = @event.participant_events.find(params[:participant_event_id])
      accommodation = participant_event.accommodation

      participant_event.room_assignment&.destroy if accommodation.rooming_exempt == false

      accommodation.update!(rooming_exempt: !accommodation.rooming_exempt)

      load_assignments_data

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace("summary_bar", partial: "admin/rooming_wizard/summary_bar"),
            turbo_stream.replace("unassigned_sidebar", partial: "admin/rooming_wizard/unassigned_sidebar"),
            turbo_stream.replace("rooms_container", partial: "admin/rooming_wizard/rooms_container")
          ]
        end
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug) }
      end
    end

    def finalize
      @rooms = @event.rooms.includes(:event, room_assignments: { participant_event: [ :event, :participant, :accommodation, :scans ] }).order(:name, :created_at).load
      @stats = calculate_finalize_stats
      @hotel_scan_context = @event.hotel_scan_context
    end

    def do_finalize
      @rooming_plan.finalize!(current_user)

      redirect_to export_csv_admin_event_rooming_wizard_path(@event.slug), notice: "Rooming finalized successfully"
    end

    def export_csv
      respond_to do |format|
        format.html
        format.csv do
          csv_data = Rooming::CsvExporter.new(@event).generate
          send_data csv_data,
            filename: "#{@event.slug}_rooming_#{Date.current.iso8601}.csv",
            type: "text/csv"
        end
      end
    end

    def lock
      @rooming_plan.lock!
      redirect_to assignments_admin_event_rooming_wizard_path(@event.slug), notice: "Rooming assignments locked"
    end

    def unlock
      @rooming_plan.unlock!
      redirect_to assignments_admin_event_rooming_wizard_path(@event.slug), notice: "Rooming assignments unlocked"
    end

    private

    def set_event
      @event = Event.find_by!(slug: params[:event_slug])
    end

    def authorize_rooming!
      authorize @event, :manage_rooming?
    end

    def set_rooming_plan
      @rooming_plan = @event.rooming_plan || @event.create_rooming_plan!(
        created_by_user: current_user,
        room_capacity: 2
      )
    end

    def room_params
      params.permit(:name, :capacity, :staff_only, :notes, :staff_names)
    end

    def require_unlocked!
      return unless @rooming_plan.locked?

      respond_to do |format|
        format.html { redirect_to assignments_admin_event_rooming_wizard_path(@event.slug), alert: "Rooming is locked and cannot be modified" }
        format.json { render json: { error: "Rooming is locked" }, status: :forbidden }
        format.turbo_stream { head :forbidden }
      end
    end

    def latest_wizard_step_path
      case @rooming_plan.status
      when "finalized"
        finalize_admin_event_rooming_wizard_path(@event.slug)
      when "auto_assigned"
        assignments_admin_event_rooming_wizard_path(@event.slug)
      when "preferences_linked"
        assignments_admin_event_rooming_wizard_path(@event.slug)
      else
        if @event.rooms.any?
          preferences_admin_event_rooming_wizard_path(@event.slug)
        else
          setup_admin_event_rooming_wizard_path(@event.slug)
        end
      end
    end

    def load_assignments_data
      @rooms = @event.rooms
        .includes(:event, room_assignments: { participant_event: [ :event, :accommodation, { participant: :sibling_groups } ] })
        .ordered
        .load
      @unassigned = scope_to_group(@event.participant_events)
        .includes(:event, :accommodation, :roommate_preferences, participant: :sibling_groups)
        .left_joins(:room_assignment)
        .where(room_assignments: { id: nil })
        .where(status: %w[complete in_progress])
        .joins(:accommodation)
        .where(accommodations: { rooming_exempt: false })
        .load

      @exempt = scope_to_group(@event.participant_events)
        .includes(:event, :accommodation)
        .where(status: %w[complete in_progress])
        .joins(:accommodation)
        .where(accommodations: { rooming_exempt: true })
        .load

      @needs_acknowledgment = RoomAssignment
        .joins(room: :event)
        .where(events: { id: @event.id })
        .needing_acknowledgment
        .load
    end

    def calculate_participant_stats
      participant_events = scope_to_group(@event.participant_events)
        .includes(:participant, :accommodation)
        .where(status: %w[complete in_progress])
        .joins(:accommodation)

      event_date = @event.starts_at&.to_date || Date.current

      stats = {
        total: participant_events.count,
        by_gender: Hash.new(0),
        by_age: Hash.new(0),
        age_18_count: 0,
        missing_gender: 0
      }

      participant_events.each do |pe|
        gender = pe.accommodation&.gender_identity || "unknown"
        stats[:by_gender][gender] += 1
        stats[:missing_gender] += 1 if gender == "unknown"

        age = pe.participant.age_on(event_date)
        if age
          stats[:by_age][age] += 1
          stats[:age_18_count] += 1 if age == 18
        end
      end

      stats
    end

    def calculate_assignment_flags(participant_event, room)
      flags = {}

      if participant_event.accommodation&.trans_or_nb?
        flags["trans_nb_pairing"] = true
      end

      existing_occupants = room.participant_events.where.not(id: participant_event.id)
      if existing_occupants.any?
        ages = existing_occupants.map(&:age_on_event).compact + [ participant_event.age_on_event ].compact
        if ages.size >= 2
          gap = ages.max - ages.min
          flags["age_gap"] = gap if gap > 2
        end
      end

      flags
    end

    def find_suggested_siblings
      participants = @event.participants.includes(:sibling_groups).to_a

      by_surname = participants.group_by { |p| p.legal_last_name&.downcase&.strip }

      by_surname
        .select { |surname, group| surname.present? && group.size >= 2 }
        .map do |surname, group|
          participant_ids = group.map(&:id).to_set
          all_grouped_together = group.all? { |p| p.sibling_groups.any? } &&
            group.first.sibling_groups.any? do |sg|
              (sg.participant_ids.to_set & participant_ids) == participant_ids
            end

          {
            surname: surname.titleize,
            participants: group,
            already_grouped: all_grouped_together
          }
        end
        .sort_by { |s| [ s[:already_grouped] ? 1 : 0, -s[:participants].size ] }
    end

    def selected_group
      return nil unless @event.groups_enabled? && params[:group_id].present?
      @selected_group ||= @event.groups.find_by(id: params[:group_id])
    end
    helper_method :selected_group

    def scope_to_group(relation)
      group = selected_group
      return relation unless group
      relation.where(id: GroupMembership.where(group_id: group.id).select(:participant_event_id))
    end

    def calculate_finalize_stats
      rooms = @rooms

      {
        total_rooms: rooms.size,
        assigned_participants: RoomAssignment.joins(room: :event).where(events: { id: @event.id }).count,
        unassigned_participants: @event.participant_events.left_joins(:room_assignment).where(room_assignments: { id: nil }).where(status: %w[complete in_progress]).joins(:accommodation).count,
        rooms_needing_acknowledgment: RoomAssignment.joins(room: :event).where(events: { id: @event.id }).needing_acknowledgment.select(:room_id).distinct.count,
        rooms_with_age_gap: rooms.select { |r| r.age_gap > 2 }.count
      }
    end
  end
end
