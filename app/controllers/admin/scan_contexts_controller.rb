module Admin
  class ScanContextsController < BaseController
    before_action :require_event_selected
    before_action :set_scan_context, only: [ :edit, :update, :destroy ]

    def index
      @scan_contexts = current_event.scan_contexts.reorder(
        ScanContext.arel_table[:starts_at].asc.nulls_last,
        :position, :created_at
      )
    end

    def new
      @scan_context = current_event.scan_contexts.new
    end

    def create
      @scan_context = current_event.scan_contexts.new(scan_context_params)
      if @scan_context.save
        redirect_to admin_event_scan_contexts_path(current_event), notice: "Scan context created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @scan_context.update(scan_context_params)
        redirect_to admin_event_scan_contexts_path(current_event), notice: "Scan context updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @scan_context.scans.exists?
        redirect_to admin_event_scan_contexts_path(current_event),
          alert: "Cannot delete a context that has scans. Remove or reassign scans first."
      elsif @scan_context.destroy
        redirect_to admin_event_scan_contexts_path(current_event), notice: "Scan context deleted."
      else
        redirect_to admin_event_scan_contexts_path(current_event),
          alert: @scan_context.errors.full_messages.to_sentence
      end
    end

    private

    def set_scan_context
      @scan_context = current_event.scan_contexts.find(params[:id])
      @record = @scan_context
    end

    def scan_context_params
      params.require(:scan_context).permit(:name, :checks_in, :is_airport, :position, :starts_at, :ends_at)
    end
  end
end
