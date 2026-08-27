module Admin
  class ExportsController < BaseController
    before_action :require_event_selected

    def index
      @categories = Exports::FieldRegistry.categories_for(role: current_role, global_admin: current_user.global_admin?)
      @fields_by_category = Exports::FieldRegistry.fields_for(role: current_role, global_admin: current_user.global_admin?).group_by(&:category)
      @templates = current_event.export_templates.order(:name)
      # Only offer presets the current role can fully export (the legacy page
      # likewise hid export types the user couldn't run).
      preset_keys = Exports::FieldRegistry.preset_keys_for(role: current_role, global_admin: current_user.global_admin?)
      @presets = Exports::FieldRegistry::PRESETS.select { |_, preset| (preset[:columns] - preset_keys).empty? }
      @prefill = resolve_prefill
    end

    def create
      config = resolve_config
      return if performed?

      denied = (config[:columns] + config[:filters].map { |f| f.field.key }) - permitted_keys
      if denied.any?
        return redirect_to admin_event_exports_path(current_event),
          alert: "You are not authorized to export: #{denied.map { |k| Exports::FieldRegistry.fetch(k)&.label || k }.join(', ')}."
      end

      if config[:columns].empty?
        return redirect_to admin_event_exports_path(current_event), alert: "Select at least one column to export."
      end

      builder = Exports::CsvBuilder.new(
        event: current_event,
        columns: config[:columns],
        filters: config[:filters],
        row_mode: config[:row_mode]
      )
      data = builder.to_csv

      AuditLog.log!(
        action: :export,
        record: current_event,
        actor: current_user,
        event: current_event,
        metadata: {
          columns: config[:columns],
          filters: config[:filters].map(&:to_h),
          row_mode: config[:row_mode],
          template_id: config[:template]&.id,
          row_count: builder.row_count
        }
      )

      send_data data,
        filename: "#{current_event.slug}_#{config[:name]}_#{Date.current.iso8601}.csv",
        type: "text/csv"
    end

    private

    def current_role
      @current_role ||= current_user.role_for_event(current_event)
    end

    def permitted_keys
      @permitted_keys ||= Exports::FieldRegistry.permitted_keys(role: current_role, global_admin: current_user.global_admin?)
    end

    def resolve_prefill
      prefill =
        if params[:template_id].present?
          template = current_event.export_templates.find_by(id: params[:template_id])
          return nil unless template

          { columns: template.columns, filters: Array(template.filters).map { |f| f.to_h.stringify_keys }, row_mode: template.row_mode }
        elsif params[:preset].present? && (preset = Exports::FieldRegistry::PRESETS[params[:preset]])
          { columns: preset[:columns], filters: [], row_mode: preset[:row_mode] }
        end
      return nil unless prefill

      strip_unpermitted_from_prefill(prefill)
    end

    # A template can reference fields the current user may not export (saved
    # by a more privileged role, or after a role change). Silently rendering
    # the remainder would produce a misleading export — a dropped filter means
    # MORE rows, not fewer — so strip them and warn loudly.
    def strip_unpermitted_from_prefill(prefill)
      denied_columns = prefill[:columns].map(&:to_s) - permitted_keys
      denied_filters = prefill[:filters].reject { |f| permitted_keys.include?(f["field"].to_s) }
      denied = denied_columns + denied_filters.map { |f| f["field"].to_s }
      return prefill if denied.empty?

      labels = denied.map { |key| Exports::FieldRegistry.fetch(key)&.label || key }
      flash.now[:alert] = "This template includes fields you are not authorized to export, which were removed: " \
        "#{labels.join(', ')}. The export below will NOT be filtered or populated by them."

      {
        columns: prefill[:columns].map(&:to_s) & permitted_keys,
        filters: prefill[:filters] - denied_filters,
        row_mode: prefill[:row_mode]
      }
    end

    def resolve_config
      if params[:template_id].present?
        template = current_event.export_templates.find(params[:template_id])
        return {
          template: template,
          name: template.name.parameterize(separator: "_"),
          columns: template.columns.map(&:to_s),
          filters: template.filter_objects,
          row_mode: template.row_mode
        }
      end

      # Legacy bookmarked POSTs (?export_type=participants) map to presets.
      preset_key = params[:preset].presence || params[:export_type].presence
      if preset_key.present?
        preset = Exports::FieldRegistry::PRESETS[preset_key]
        unless preset
          return redirect_to(admin_event_exports_path(current_event), alert: "Invalid export type.")
        end

        return { template: nil, name: preset_key, columns: preset[:columns], filters: [], row_mode: preset[:row_mode] }
      end

      row_mode = params[:row_mode].presence || "participant"
      unless Exports::FieldRegistry::ROW_MODES.include?(row_mode)
        return redirect_to(admin_event_exports_path(current_event), alert: "Invalid row mode.")
      end

      columns = Array(params[:columns]).map(&:to_s).reject(&:blank?)
      unknown = columns - Exports::FieldRegistry::FIELDS.keys
      if unknown.any?
        return redirect_to(admin_event_exports_path(current_event), alert: "Unknown export fields: #{unknown.join(', ')}.")
      end

      filters = build_filters
      return if performed?

      { template: nil, name: "custom_export", columns: columns, filters: filters, row_mode: row_mode }
    end

    def build_filters
      raw_filters.filter_map do |raw|
        next if raw["field"].blank?

        filter = Exports::Filter.build(raw)
        unless filter&.valid?
          redirect_to(admin_event_exports_path(current_event), alert: "Invalid filter on #{raw['field']}.")
          return []
        end

        filter
      end
    end

    def raw_filters
      params.fetch(:filters, {}).values.map do |f|
        f.permit(:field, :operator, :value, value: []).to_h.stringify_keys
      end
    rescue NoMethodError
      []
    end
  end
end
