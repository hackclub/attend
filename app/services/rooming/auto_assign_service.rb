module Rooming
  class AutoAssignService
    def initialize(event, group: nil)
      @event = event
      @group = group
      @rooming_plan = event.rooming_plan
      @room_capacity = @rooming_plan&.room_capacity || 2
      @assigned = []
      @unassigned = []
    end

    def call
      ActiveRecord::Base.transaction do
        clear_non_staff_assignments
        load_participants
        build_context

        auto_pair_siblings
        auto_pair_mutual_preferences
        fill_remaining_rooms

        flag_special_pairings
      end

      { assigned: @assigned.size, unassigned: @unassigned.size }
    end

    private

    def clear_non_staff_assignments
      RoomAssignment
        .joins(room: :event)
        .where(events: { id: @event.id })
        .where(staff_override: false)
        .destroy_all
    end

    def load_participants
      scope = @event.participant_events
        .includes(:participant, :accommodation, :roommate_preferences, :roommate_exclusions)
        .where(status: %w[complete in_progress])
        .joins(:accommodation)
        .where(accommodations: { rooming_exempt: false })

      scope = scope.where(id: GroupMembership.where(group_id: @group.id).select(:participant_event_id)) if @group

      @participant_events = scope.to_a
    end

    def build_context
      @event_date = @event.starts_at&.to_date || Date.current

      @exclusions = Hash.new { |h, k| h[k] = Set.new }
      @preferences = Hash.new { |h, k| h[k] = [] }
      @participant_data = {}

      @participant_events.each do |pe|
        pe.roommate_exclusions.each do |excl|
          @exclusions[pe.id].add(excl.excluded_participant_event_id)
        end

        pe.roommate_preferences.order(:rank).each do |pref|
          @preferences[pe.id] << pref.preferred_participant_event_id
        end

        @participant_data[pe.id] = {
          pe: pe,
          age: pe.participant.age_on(@event_date),
          is_18: pe.participant.age_on(@event_date) == 18,
          gender_bucket: pe.accommodation&.gender_bucket,
          allowed_genders: pe.accommodation&.allowed_roommate_gender_buckets || [],
          sibling_ids: pe.participant.siblings.pluck(:id),
          trans_or_nb: pe.accommodation&.trans_or_nb?
        }
      end

      @available = @participant_events.map(&:id).to_set
    end

    def auto_pair_siblings
      sibling_groups = SiblingGroup.includes(participants: :participant_events)
        .joins(participants: :participant_events)
        .where(participant_events: { event_id: @event.id })
        .distinct

      sibling_groups.each do |group|
        group_pes = group.participants.flat_map do |p|
          p.participant_events.select { |pe| pe.event_id == @event.id && @available.include?(pe.id) }
        end.uniq

        next if group_pes.size < 2
        next if group_pes.size > @room_capacity

        if any_excluded_pair?(group_pes)
          next
        end

        room = find_or_create_room_for_group(group_pes)
        if room
          group_pes.each do |pe|
            assign_to_room(pe, room, sibling_group: true)
          end
        end
      end
    end

    def auto_pair_mutual_preferences
      @participant_events.each do |pe|
        next unless @available.include?(pe.id)

        top_pref = @preferences[pe.id].first
        next unless top_pref && @available.include?(top_pref)

        other_top = @preferences[top_pref]&.first
        next unless other_top == pe.id

        pe_data = @participant_data[pe.id]
        other_data = @participant_data[top_pref]
        other_pe = other_data[:pe]

        next unless compatible?(pe_data, other_data)

        room = find_or_create_room_for_group([ pe, other_pe ])
        if room
          assign_to_room(pe, room)
          assign_to_room(other_pe, room)
        end
      end
    end

    def fill_remaining_rooms
      pools = partition_into_pools

      pools.each do |pool_key, pool|
        fill_pool(pool)
      end

      @participant_events.each do |pe|
        if @available.include?(pe.id)
          @unassigned << pe
        end
      end
    end

    def partition_into_pools
      pools = Hash.new { |h, k| h[k] = [] }

      @participant_events.each do |pe|
        next unless @available.include?(pe.id)

        data = @participant_data[pe.id]
        bucket = data[:gender_bucket] || "unknown"
        is_18 = data[:is_18]

        pool_key = if bucket == "nb_trans"
          "nb_trans"
        elsif is_18
          "#{bucket}_18"
        else
          bucket
        end

        pools[pool_key] << pe
      end

      pools.each do |key, pool|
        pool.sort_by! { |pe| @participant_data[pe.id][:age] || 0 }
      end

      pools
    end

    def fill_pool(pool)
      pool.each do |pe|
        next unless @available.include?(pe.id)

        pe_data = @participant_data[pe.id]

        room = find_compatible_room(pe_data)

        unless room
          room = @event.rooms.create!(capacity: @room_capacity)
        end

        assign_to_room(pe, room)

        preferred = @preferences[pe.id].select { |pref_id| @available.include?(pref_id) }

        preferred.each do |pref_id|
          break if room.reload.full?

          pref_data = @participant_data[pref_id]
          next unless compatible?(pe_data, pref_data)
          next unless room_compatible_with_participant?(room, pref_data)

          assign_to_room(pref_data[:pe], room)
        end

        while !room.reload.full? && @available.any?
          remaining_candidates = pool.select do |candidate|
            @available.include?(candidate.id) &&
              compatible?(pe_data, @participant_data[candidate.id]) &&
              room_compatible_with_participant?(room, @participant_data[candidate.id])
          end

          candidate = remaining_candidates.min_by do |c|
            (@participant_data[c.id][:age] - (pe_data[:age] || 0)).abs
          end

          break unless candidate

          assign_to_room(candidate, room)
        end
      end
    end

    def compatible?(data_a, data_b)
      return false if @exclusions[data_a[:pe].id].include?(data_b[:pe].id)
      return false if @exclusions[data_b[:pe].id].include?(data_a[:pe].id)

      are_siblings = data_a[:pe].participant.sibling_of?(data_b[:pe].participant)

      if (data_a[:is_18] || data_b[:is_18]) && !(data_a[:is_18] && data_b[:is_18])
        return false unless are_siblings
      end

      gender_compatible?(data_a, data_b)
    end

    def gender_compatible?(data_a, data_b)
      return false if data_a[:gender_bucket].nil? || data_b[:gender_bucket].nil?

      data_b[:gender_bucket].in?(data_a[:allowed_genders]) &&
        data_a[:gender_bucket].in?(data_b[:allowed_genders])
    end

    def room_compatible_with_participant?(room, participant_data)
      existing = room.room_assignments.includes(participant_event: :accommodation)

      existing.all? do |assignment|
        existing_data = @participant_data[assignment.participant_event_id]
        compatible?(existing_data, participant_data) if existing_data
      end
    end

    def find_compatible_room(participant_data)
      @event.rooms.participant_rooms.includes(:room_assignments).find do |room|
        room.can_add_participants? && room_compatible_with_participant?(room, participant_data)
      end
    end

    def find_or_create_room_for_group(participants)
      room = @event.rooms.participant_rooms.includes(:room_assignments).find do |r|
        r.can_add_participants? && r.remaining_capacity >= participants.size
      end

      room || @event.rooms.create!(capacity: @room_capacity)
    end

    def assign_to_room(pe, room, sibling_group: false)
      return unless @available.include?(pe.id)

      @available.delete(pe.id)
      @assigned << pe

      flags = {}
      pe_data = @participant_data[pe.id]

      if pe_data[:trans_or_nb]
        flags["trans_nb_pairing"] = true
      end

      if sibling_group
        ages_in_room = room.reload.room_assignments.map { |ra| @participant_data[ra.participant_event_id]&.[](:age) }.compact
        ages_in_room << pe_data[:age] if pe_data[:age]

        if ages_in_room.any? { |a| a == 18 } && ages_in_room.any? { |a| a != 18 }
          flags["18_with_non18_sibling"] = true
        end
      end

      RoomAssignment.create!(
        room: room,
        participant_event: pe,
        flags: flags
      )
    end

    def any_excluded_pair?(participant_events)
      ids = participant_events.map(&:id)
      ids.combination(2).any? do |a, b|
        @exclusions[a].include?(b) || @exclusions[b].include?(a)
      end
    end

    def flag_special_pairings
      @event.rooms.includes(room_assignments: { participant_event: [ :participant, :accommodation ] }).each do |room|
        next if room.room_assignments.empty?

        ages = room.room_assignments.map { |ra| @participant_data[ra.participant_event_id]&.[](:age) }.compact

        if ages.size >= 2
          gap = ages.max - ages.min
          if gap > 2
            room.room_assignments.each do |ra|
              ra.update!(flags: ra.flags.merge("age_gap" => gap))
            end
          end
        end

        if room.room_assignments.any? { |ra| @participant_data[ra.participant_event_id]&.[](:trans_or_nb) }
          room.room_assignments.each do |ra|
            ra.update!(flags: ra.flags.merge("trans_nb_pairing" => true))
          end
        end
      end
    end
  end
end
