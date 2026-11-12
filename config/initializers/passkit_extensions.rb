# Extend Passkit::Generator with pass.json keys the gem doesn't know about:
# relevantDates (iOS 18), poster event ticket keys (iOS 18) and
# featuredActions (iOS 27), and stop it leaving every build on disk.

module PasskitGeneratorExtensions
  # A built pass, held in memory. See generate_and_sign.
  Pkpass = Data.define(:filename, :data)

  # The gem builds each pass in tmp/passkit/<uuid>/ and zips it to
  # tmp/passkit/<uuid>.pkpass. Since 0.9 it removes the directory itself and
  # its controllers delete the archive after sending, but anything else that
  # calls generate_and_sign (or a build that fails after zipping) would still
  # leave the archive behind. Return the zip's bytes rather than its path and
  # delete both here, so no build leaves anything on disk however it ends.
  # PasskitPassesControllerExtensions#send_pass_file sends the bytes.
  def generate_and_sign
    path = super
    Pkpass.new(filename: File.basename(path), data: File.binread(path))
  ensure
    if @temporary_path
      FileUtils.rm_rf(@temporary_path)
      FileUtils.rm_f("#{@temporary_path}.pkpass")
    end
  end

  def generate_json_pass
    pass = {
      formatVersion: @pass.format_version,
      teamIdentifier: @pass.apple_team_identifier,
      authenticationToken: @pass.authentication_token,
      backgroundColor: @pass.background_color,
      description: @pass.description,
      foregroundColor: @pass.foreground_color,
      labelColor: @pass.label_color,
      locations: @pass.locations,
      logoText: @pass.logo_text,
      organizationName: @pass.organization_name,
      passTypeIdentifier: @pass.pass_type_identifier,
      serialNumber: @pass.serial_number,
      sharingProhibited: @pass.sharing_prohibited,
      suppressStripShine: @pass.suppress_strip_shine,
      voided: @pass.voided,
      webServiceURL: @pass.web_service_url
    }

    pass[:maxDistance] = @pass.max_distance if @pass.max_distance

    barcodes = @pass.barcodes || []
    if barcodes.empty?
      pass[:barcode] = @pass.barcode
    else
      pass[:barcodes] = @pass.barcodes
    end

    # passkit 0.9 dropped coupon/event_ticket/generic/store_card from
    # Passkit::Pass (they were always nil, and the pass_type block below
    # writes the real eventTicket dictionary), so they're no longer read here.
    # boarding_pass is gone too: 0.9's default is {}, which is truthy and
    # would put an empty boardingPass key on every event ticket.
    pass[:appLaunchURL] = @pass.app_launch_url if @pass.app_launch_url
    pass[:associatedStoreIdentifiers] = @pass.associated_store_identifiers unless @pass.associated_store_identifiers.empty?
    pass[:beacons] = @pass.beacons unless @pass.beacons.empty?
    pass[:expirationDate] = @pass.expiration_date if @pass.expiration_date
    pass[:groupingIdentifier] = @pass.grouping_identifier if @pass.grouping_identifier
    pass[:nfc] = @pass.nfc if @pass.nfc
    pass[:relevantDate] = @pass.relevant_date if @pass.relevant_date
    pass[:semantics] = @pass.semantics if @pass.semantics
    pass[:userInfo] = @pass.user_info if @pass.user_info

    # Passkit::Pass only delegates the gem's own attribute list, so anything
    # newer has to be read off the pass class instance directly.
    instance = @pass.instance

    # iOS 18+ relevantDates support
    if instance.respond_to?(:relevant_dates) && instance.relevant_dates.present?
      pass[:relevantDates] = instance.relevant_dates
    end

    # Poster event ticket (iOS 18) and featured action (iOS 27) keys. Older
    # Wallet versions ignore keys they don't know, so these are safe to
    # always send; see Passkit::EventTicket#additional_pass_keys.
    if instance.respond_to?(:additional_pass_keys)
      pass.merge!(instance.additional_pass_keys.compact_blank)
    end

    pass[@pass.pass_type] = {
      headerFields: @pass.header_fields,
      primaryFields: @pass.primary_fields,
      secondaryFields: @pass.secondary_fields,
      auxiliaryFields: @pass.auxiliary_fields,
      backFields: @pass.back_fields
    }

    File.write(@temporary_path.join("pass.json"), pass.to_json)
  end
end

module PasskitPassesControllerExtensions
  # A pass whose participant event is gone can never be built again, so tell
  # Wallet it's gone. Since 0.9 the gem answers If-Modified-Since with a 304
  # before building (which used to be our own shortcut here), and a pass with
  # no generator falls back to its own updated_at, so without this check an
  # orphaned pass would be reported as unchanged forever.
  def show
    return head(:gone) if requested_pass_orphaned?

    super
  rescue ActiveRecord::RecordNotFound
    head :gone
  end

  private

  # Anything this doesn't answer (no header, a bad token) falls through to
  # the gem, which rejects it.
  def requested_pass_orphaned?
    token = request.headers["Authorization"]&.split(" ")&.last
    return false if token.blank?

    pass = Passkit::Pass.find_by(serial_number: params[:serial_number], authentication_token: token)
    pass.present? && pass.generator.nil?
  end

  # Both actions hand Passkit::PassDelivery#send_pass_file whatever
  # Passkit::Generator#generate_and_sign returned, which
  # PasskitGeneratorExtensions makes the pass itself rather than a path.
  def send_pass_file(pkpass, type:, filename: nil)
    send_data(pkpass.data, type: type, disposition: "attachment", filename: filename || pkpass.filename)
  end
end

# The gem dates a pass by its generator (the participant event) alone, but
# WalletPassUpdateService touches the pass itself when the event or the
# participant changes. Ignoring that touch meant Wallet was pushed an update,
# asked for the pass and got 304 ("Server requested update ... but the pass
# was unchanged"), so those edits never reached the device.
module PasskitPassExtensions
  def last_update
    [ super, updated_at ].compact.max
  end
end

# Concurrent registrations for the same device race find_or_create_by!:
# the loser fails Passkit::Device's uniqueness validation with RecordInvalid,
# which find_or_create_by! doesn't recover from (it only rescues the
# db-level RecordNotUnique). Retrying once finds the winner's row. (ATTEND-7R)
module PasskitRegistrationsControllerExtensions
  def register_device
    retried = false
    begin
      super
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      raise if retried
      retried = true
      retry
    end
  end
end

Rails.application.config.after_initialize do
  next if ENV["SECRET_KEY_BASE_DUMMY"]

  Passkit::Generator.prepend(PasskitGeneratorExtensions)
  Passkit::Pass.prepend(PasskitPassExtensions)
  Passkit::Api::V1::PassesController.prepend(PasskitPassesControllerExtensions)
  Passkit::Api::V1::RegistrationsController.prepend(PasskitRegistrationsControllerExtensions)
end
