module Admin
  class ImportsController < BaseController
    before_action :require_event_selected
    before_action :authorize_import

    # The participant fields Participant validates, keyed as they're stored in
    # rows_data, with the template header that fills them.
    REQUIRED_COLUMNS = { "legal_first_name" => "First Name", "legal_last_name" => "Last Name" }.freeze

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
        return render_console_file_error("Participants CSV is required.") if request.variant.include?(:console)

        redirect_to new_admin_event_import_path(current_event), alert: "Please select a CSV file to import."
        return
      end

      csv_content = params[:csv_file].read
      # A held event never emails on import, whatever the box says: the
      # invitations are recorded and go out when the hold is released.
      send_invitations = params[:send_invitations] != "0" && !current_event.onboarding_invites_held?

      begin
        rows = parse_csv(csv_content)
      rescue CSV::MalformedCSVError => e
        return reject_csv_file("This file isn't a valid CSV: #{e.message}")
      rescue EncodingError
        return reject_csv_file("This file couldn't be read. Save it from your spreadsheet as \"CSV UTF-8\" and upload it again.")
      end

      if rows.empty?
        return render_console_file_error("The file has no rows to import. Check it against the template.") if request.variant.include?(:console)

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

      # Say how the file was read, so an admin checks the accented names
      # before importing (Mac Roman and other code pages read as garbage).
      redirect_to preview_admin_event_import_path(current_event, @import_batch, read_as: @read_as)
    end

    def preview
      @import_batch = current_event.import_batches.find(params[:id])

      unless @import_batch.previewing?
        redirect_to progress_admin_event_import_path(current_event, @import_batch)
        return
      end

      @rows = @import_batch.rows_data.map(&:with_indifferent_access)
      @valid_rows = []
      @skipped_rows = []
      # A header the file lacks leaves its key out of every row.
      @missing_columns = REQUIRED_COLUMNS.reject { |key, _| @rows.any? { |row| row.key?(key) } }.values
      importing_rows = {}
      lookups = preview_lookups(@rows)

      @rows.each_with_index do |row, index|
        email = row[:email]&.downcase&.strip
        next if email.blank?

        existing_participant = lookups[:participants][email]
        existing_pe = existing_participant && lookups[:registered].include?(existing_participant.id)

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
        elsif importing_rows[email]
          # The job imports the first row and skips this one as registered.
          @skipped_rows << row_info.merge(reason: "Same email as row #{importing_rows[email]}")
        elsif (failure = rejection_reason(row, existing_participant, lookups))
          @skipped_rows << row_info.merge(reason: failure, failing: true)
        else
          importing_rows[email] = row_info[:row_number]
          @valid_rows << row_info
        end
      end
    end

    def confirm
      @import_batch = current_event.import_batches.find(params[:id])

      unless @import_batch.previewing?
        redirect_to progress_admin_event_import_path(current_event, @import_batch), alert: "This import has already been started."
        return
      end

      @import_batch.update!(status: :pending)
      ProcessImportBatchJob.perform_later(@import_batch.id)

      redirect_to progress_admin_event_import_path(current_event, @import_batch)
    end

    def progress
      @import_batch = current_event.import_batches.find(params[:id])
    end

    def cancel
      @import_batch = current_event.import_batches.find(params[:id])

      if @import_batch.previewing? || @import_batch.pending?
        @import_batch.destroy
        redirect_to new_admin_event_import_path(current_event), notice: "Import cancelled."
      else
        redirect_to progress_admin_event_import_path(current_event, @import_batch), alert: "Cannot cancel an import that is already in progress."
      end
    end

    private

    # The console shows upload problems under the file field rather than as
    # a flash on a fresh form; the original UI keeps its redirects.
    def render_console_file_error(message)
      @csv_file_errors = [ message ]
      render :new, status: :unprocessable_entity
    end

    def reject_csv_file(message)
      return render_console_file_error(message) if request.variant.include?(:console)

      redirect_to new_admin_event_import_path(current_event), alert: message
    end

    # Importing a CSV invites everyone in it, so it takes the same permission as
    # the invite form: event admins only.
    def authorize_import
      authorize current_event, :invite_participants?
    end

    def parse_csv(csv_content)
      content = decode_csv(csv_content).delete("\u0000")
      # Excel in many European locales separates with semicolons; "Unicode
      # Text" uses tabs. The first rows tell which.
      col_sep = [ ",", ";", "\t" ].max_by { |sep| separator_fit(content, sep) }
      csv = CSV.parse(content, headers: true, col_sep: col_sep)

      # Two headers can name one field. The template's own header beats an
      # alias (a form's "Email Address" is often the parent who filled it in,
      # its "Email" question the participant), then the leftmost column; a
      # blank cell falls through to the next column of the same standing.
      columns = csv.headers.each_with_index.filter_map do |header, index|
        key = CsvImportService.column_for(header)
        [ key.to_s, index, CsvImportService.template_header?(header) ? 0 : 1 ] if key
      end.sort_by { |_, index, rank| [ rank, index ] }

      # An alias never stands in for a template header the file also has, not
      # even for a blank cell: a row that left the participant's own "Email"
      # empty must not be imported under the parent's "Email Address".
      best_rank = columns.each_with_object({}) { |(key, _, rank), ranks| ranks[key] ||= rank }
      columns = columns.select { |(key, _, rank)| rank == best_rank[key] }

      csv.map do |row|
        columns.each_with_object({}) do |(key, index, _), mapped|
          mapped[key] ||= row[index]&.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "").presence
        end
      end.reject { |row| row["email"].blank? }
    end

    # Rows sampled to pick the separator.
    SNIFF_ROWS = 5

    # How well a separator fits the file: the narrowest row it produces, then
    # the header row's width. Counting separator characters instead reads a
    # semicolon file whose header text contains a comma as comma-separated,
    # and chokes on a comma inside a quoted header.
    def separator_fit(content, col_sep)
      rows = CSV.new(content, col_sep: col_sep).first(SNIFF_ROWS)
      return [ 0, 0 ] if rows.empty?

      [ rows.map(&:length).min, rows.first.length ]
    rescue CSV::MalformedCSVError
      [ 0, 0 ]
    end

    # Excel's "CSV UTF-8" starts with a byte order mark, its "Unicode Text" is
    # UTF-16, and its plain "CSV" on Windows is Windows-1252, where accented
    # names aren't valid UTF-8.
    def decode_csv(csv_content)
      bytes = csv_content.b
      { "\xFF\xFE".b => Encoding::UTF_16LE, "\xFE\xFF".b => Encoding::UTF_16BE }.each do |bom, encoding|
        return bytes.delete_prefix(bom).force_encoding(encoding).encode(Encoding::UTF_8) if bytes.start_with?(bom)
      end

      content = bytes.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8)
      return content if content.valid_encoding?

      @read_as = "windows-1252"
      content.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
    end

    # Everything the preview will ask the database about, in five queries for
    # the whole file. The loop runs over every row inside the request, so a
    # participant, registration, ban and guardian lookup per row doesn't scale
    # to the thousand-row sheets organizers upload.
    def preview_lookups(rows)
      emails = rows.filter_map { |row| row[:email]&.downcase&.strip.presence }.uniq
      parent_emails = rows.filter_map { |row| row[:parent_email]&.downcase&.strip.presence }.uniq
      participants = emails.any? ? Participant.where("LOWER(email) IN (?)", emails).includes(:user).to_a : []
      slack_ids = participants.flat_map { |participant| Ban.slack_ids_for(participant) }

      {
        participants: participants.index_by { |participant| participant.email.downcase },
        registered: participants.any? ? ParticipantEvent.where(event: current_event, participant: participants).pluck(:participant_id).to_set : Set.new,
        banned_emails: Ban.banned_emails(emails),
        banned_slack_ids: Ban.banned_slack_ids(slack_ids),
        guardian_emails: parent_emails.any? ? Guardian.where("LOWER(email) IN (?)", parent_emails).pluck(Arel.sql("LOWER(email)")).to_set : Set.new
      }
    end

    def rejection_reason(row, existing_participant, lookups)
      banned = lookups[:banned_emails].include?(row[:email].to_s.downcase.strip) ||
        Ban.slack_ids_for(existing_participant).compact_blank.any? { |id| lookups[:banned_slack_ids].include?(id.strip.upcase) }

      ProcessImportBatchJob.new.rejection_reason(
        row, current_event, existing_participant,
        banned: banned,
        known_guardian: lookups[:guardian_emails].include?(row[:parent_email].to_s.downcase.strip)
      )
    end
  end
end
