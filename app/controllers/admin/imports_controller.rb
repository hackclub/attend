module Admin
  class ImportsController < BaseController
    before_action :require_event_selected

    COLUMN_MAPPING = CsvImportService::COLUMN_MAPPING

    def new
    end

    def template
      headers = CsvImportService::COLUMN_MAPPING.keys
      csv_data = CSV.generate do |csv|
        csv << headers
      end

      send_data csv_data, filename: "participant_import_template.csv", type: "text/csv"
    end

    def create
      unless params[:csv_file].present?
        redirect_to new_admin_event_import_path(current_event), alert: "Please select a CSV file to import."
        return
      end

      csv_content = params[:csv_file].read
      send_invitations = params[:send_invitations] != "0"

      rows = parse_csv(csv_content)

      if rows.empty?
        redirect_to new_admin_event_import_path(current_event), alert: "No valid rows found in CSV."
        return
      end

      @import_batch = ImportBatch.create!(
        event: current_event,
        status: :previewing,
        total_count: rows.count,
        rows_data: rows,
        send_invitations: send_invitations
      )

      redirect_to preview_admin_event_import_path(current_event, @import_batch)
    end

    def preview
      @import_batch = ImportBatch.find(params[:id])

      unless @import_batch.previewing?
        redirect_to progress_admin_event_import_path(current_event, @import_batch)
        return
      end

      @rows = @import_batch.rows_data.map(&:with_indifferent_access)
      @valid_rows = []
      @skipped_rows = []

      @rows.each_with_index do |row, index|
        email = row[:email]&.downcase&.strip
        next if email.blank?

        existing_pe = Participant.find_by("LOWER(email) = ?", email)&.participant_events&.find_by(event: current_event)

        row_info = {
          row_number: index + 2,
          email: email,
          name: [ row[:legal_first_name], row[:legal_last_name] ].compact.join(" "),
          parent_email: row[:parent_email],
          # The import drops a parent column that repeats the participant's own
          # address; say so here rather than after the fact.
          parent_email_conflict: row[:parent_email].present? &&
            row[:parent_email].to_s.strip.downcase == email
        }

        if existing_pe
          @skipped_rows << row_info.merge(reason: "Already registered")
        else
          @valid_rows << row_info
        end
      end
    end

    def confirm
      @import_batch = ImportBatch.find(params[:id])

      unless @import_batch.previewing?
        redirect_to progress_admin_event_import_path(current_event, @import_batch), alert: "This import has already been started."
        return
      end

      @import_batch.update!(status: :pending)
      ProcessImportBatchJob.perform_later(@import_batch.id)

      redirect_to progress_admin_event_import_path(current_event, @import_batch)
    end

    def progress
      @import_batch = ImportBatch.find(params[:id])
    end

    def cancel
      @import_batch = ImportBatch.find(params[:id])

      if @import_batch.previewing? || @import_batch.pending?
        @import_batch.destroy
        redirect_to new_admin_event_import_path(current_event), notice: "Import cancelled."
      else
        redirect_to progress_admin_event_import_path(current_event, @import_batch), alert: "Cannot cancel an import that is already in progress."
      end
    end

    private

    def parse_csv(csv_content)
      csv_content = csv_content.force_encoding("UTF-8")
      csv_content = csv_content.sub(/\A\xEF\xBB\xBF/u, "")

      csv = CSV.parse(csv_content, headers: true)

      csv.map do |row|
        mapped = {}
        row.each do |header, value|
          key = COLUMN_MAPPING[header]
          mapped[key.to_s] = value&.strip if key
        end
        mapped
      end.reject { |row| row["email"].blank? }
    end
  end
end
