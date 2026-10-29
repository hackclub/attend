# Extend Passkit::Generator with pass.json keys the gem doesn't know about:
# relevantDates (iOS 18), poster event ticket keys (iOS 18) and
# featuredActions (iOS 27), and stop it leaving every build on disk.

module PasskitGeneratorExtensions
  # A built pass, held in memory. See generate_and_sign.
  Pkpass = Data.define(:filename, :data)

  # The gem builds each pass in tmp/passkit/<uuid>/, zips it to
  # tmp/passkit/<uuid>.pkpass and deletes neither (file_name is a fresh UUID
  # per pass, so its own rm_rf never matches an earlier build). Return the
  # zip's bytes rather than its path, and delete both, so no build leaves
  # anything behind: passes#show builds before it checks If-Modified-Since
  # and drops the pass on a 304, and a send_file'd path is only read after
  # the action returns. PasskitPassesControllerExtensions#send_file sends it.
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

    pass[:appLaunchURL] = @pass.app_launch_url if @pass.app_launch_url
    pass[:associatedStoreIdentifiers] = @pass.associated_store_identifiers unless @pass.associated_store_identifiers.empty?
    pass[:beacons] = @pass.beacons unless @pass.beacons.empty?
    pass[:boardingPass] = @pass.boarding_pass if @pass.boarding_pass
    pass[:coupon] = @pass.coupon if @pass.coupon
    pass[:eventTicket] = @pass.event_ticket if @pass.event_ticket
    pass[:expirationDate] = @pass.expiration_date if @pass.expiration_date
    pass[:generic] = @pass.generic if @pass.generic
    pass[:groupingIdentifier] = @pass.grouping_identifier if @pass.grouping_identifier
    pass[:nfc] = @pass.nfc if @pass.nfc
    pass[:relevantDate] = @pass.relevant_date if @pass.relevant_date
    pass[:semantics] = @pass.semantics if @pass.semantics
    pass[:store_card] = @pass.store_card if @pass.store_card
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
  def show
    super
  rescue ActiveRecord::RecordNotFound
    head :gone
  end

  private

  # Both actions send_file whatever Passkit::Generator#generate_and_sign
  # returned, which PasskitGeneratorExtensions makes the pass itself.
  def send_file(pkpass, options = {})
    send_data(pkpass.data, options.reverse_merge(filename: pkpass.filename))
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
  Passkit::Api::V1::PassesController.prepend(PasskitPassesControllerExtensions)
  Passkit::Api::V1::RegistrationsController.prepend(PasskitRegistrationsControllerExtensions)
end
