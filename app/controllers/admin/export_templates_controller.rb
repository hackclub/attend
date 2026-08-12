module Admin
  class ExportTemplatesController < BaseController
    before_action :require_event_selected

    def create
      columns = Array(params[:columns]).map(&:to_s).reject(&:blank?)
      filters = raw_filters.reject { |f| f["field"].blank? }

      denied = (columns + filters.map { |f| f["field"] }) - permitted_keys
      if denied.any?
        return redirect_to admin_event_exports_path(current_event),
          alert: "You cannot save a template with fields you are not authorized to export."
      end

      template = current_event.export_templates.new(
        name: params[:template_name].to_s.strip,
        columns: columns,
        filters: filters,
        row_mode: params[:row_mode].presence || "participant",
        created_by: current_user
      )

      if template.save
        redirect_to admin_event_exports_path(current_event, template_id: template.id), notice: "Template \"#{template.name}\" saved."
      else
        redirect_to admin_event_exports_path(current_event), alert: "Could not save template: #{template.errors.full_messages.join(', ')}"
      end
    end

    def destroy
      template = current_event.export_templates.find(params[:id])

      unless can_delete?(template)
        return redirect_to admin_event_exports_path(current_event), alert: "You are not authorized to delete this template."
      end

      template.destroy
      redirect_to admin_event_exports_path(current_event), notice: "Template \"#{template.name}\" deleted."
    end

    private

    def can_delete?(template)
      template.created_by_id == current_user.id ||
        current_user.global_admin? ||
        current_user.role_for_event(current_event) == "event_admin"
    end

    def permitted_keys
      Exports::FieldRegistry.permitted_keys(
        role: current_user.role_for_event(current_event),
        global_admin: current_user.global_admin?
      )
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
