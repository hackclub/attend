module Admin
  class AuditLogsController < BaseController
    include IncidentAuditVisibility

    before_action :require_audit_access
    before_action :set_audit_log, only: [ :show ]

    def index
      @audit_logs = AuditLog.includes(:actor, :event).order(created_at: :desc)

      unless current_user.global_admin?
        @audit_logs = @audit_logs.where(event_id: current_user.assigned_events.pluck(:id))
        @audit_logs = exclude_hidden_incident_logs(@audit_logs)
      end

      if params[:event_id].present?
        @audit_logs = @audit_logs.where(event_id: params[:event_id])
      end

      if params[:user_id].present?
        @audit_logs = @audit_logs.where(actor_user_id: params[:user_id])
      end

      if params[:action_type].present?
        @audit_logs = @audit_logs.where(action: params[:action_type])
      end

      if params[:record_type].present?
        @audit_logs = @audit_logs.where(record_type: params[:record_type])
      end

      if params[:start_date].present?
        @audit_logs = @audit_logs.where("created_at >= ?", Date.parse(params[:start_date]).beginning_of_day)
      end

      if params[:end_date].present?
        @audit_logs = @audit_logs.where("created_at <= ?", Date.parse(params[:end_date]).end_of_day)
      end

      @audit_logs = @audit_logs.limit(500)
    end

    def show
      @record_versions = if can_view_record_history?(@audit_log)
        PaperTrail::Version
          .where(item_type: @audit_log.record_type, item_id: @audit_log.record_id)
          .order(created_at: :desc)
          .limit(50)
      else
        PaperTrail::Version.none
      end
    end

    # Raw PaperTrail feed across every record in the app. Versions carry no
    # event metadata, so this cannot be scoped to an event admin's events —
    # global admins only.
    def versions
      unless current_user.global_admin?
        return redirect_to admin_audit_logs_path, alert: "Only global admins can view raw record versions."
      end

      @versions = PaperTrail::Version.order(created_at: :desc)

      if params[:item_type].present?
        @versions = @versions.where(item_type: params[:item_type])
      end

      if params[:item_id].present?
        @versions = @versions.where(item_id: params[:item_id])
      end

      if params[:user_id].present?
        @versions = @versions.where(whodunnit: params[:user_id].to_s)
      end

      if params[:event].present?
        @versions = @versions.where(event: params[:event])
      end

      if params[:start_date].present?
        @versions = @versions.where("created_at >= ?", Date.parse(params[:start_date]).beginning_of_day)
      end

      if params[:end_date].present?
        @versions = @versions.where("created_at <= ?", Date.parse(params[:end_date]).end_of_day)
      end

      @versions = @versions.limit(500)

      whodunnit_ids = @versions.map(&:whodunnit).compact.uniq
      @users_by_id = User.where(id: whodunnit_ids).index_by(&:id)
    end

    private

    def set_audit_log
      @audit_log = AuditLog.find(params[:id])

      unless can_view_audit_log?(@audit_log)
        redirect_to admin_audit_logs_path, alert: "You are not authorized to view this log."
      end
    end

    def can_view_audit_log?(audit_log)
      return true if current_user.global_admin?
      return false unless audit_log.event_id.present? && current_user.event_admin_for?(audit_log.event)

      # The same rows exclude_hidden_incident_logs lists: a reporter outside
      # the incident's roles can open the row for what they filed, and nothing
      # about the comments or edits that followed.
      case audit_log.record_type
      when "Incident"
        casework_incident_ids.include?(audit_log.record_id) ||
          (audit_log.record_create? && visible_incident_ids.include?(audit_log.record_id))
      when "IncidentComment"
        incident_id = IncidentComment.find_by(id: audit_log.record_id)&.incident_id
        incident_id.present? && casework_incident_ids.include?(incident_id)
      else
        true
      end
    end

    # The record history is every version of the record, so on an incident it
    # is the timeline the incident page keeps from reporters.
    def can_view_record_history?(audit_log)
      return true if current_user.global_admin?
      return true unless audit_log.record_type == "Incident"

      casework_incident_ids.include?(audit_log.record_id)
    end

    def require_audit_access
      return if current_user.global_admin?

      unless current_user.event_role_assignments.exists?(role: :event_admin)
        redirect_to admin_root_path, alert: "Only global admins or event admins can access audit logs."
      end
    end
  end
end
