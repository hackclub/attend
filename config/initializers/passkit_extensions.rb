# Extend Passkit::Generator with pass.json keys the gem doesn't know about:
# relevantDates (iOS 18), poster event ticket keys (iOS 18) and
# featuredActions (iOS 27).

module PasskitGeneratorExtensions
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
  # Wallet asks with If-Modified-Since whenever it checks a pass for changes,
  # but the gem builds, signs and zips the whole bundle (images and all)
  # before comparing, so an unchanged pass cost as much as a new one: a 304
  # once took 36s while it rendered that event's images.
  def show
    return head(:not_modified) if pass_unchanged_since_request?

    super
  rescue ActiveRecord::RecordNotFound
    head :gone
  end

  private

  # The gem's own lookup and comparison from #show, done before building.
  # Anything this doesn't answer (no header, a bad token, a pass whose
  # participant event is gone) falls through to the gem unchanged.
  def pass_unchanged_since_request?
    since = request.if_modified_since
    token = request.headers["Authorization"]&.split(" ")&.last
    return false if since.nil? || token.blank?

    pass = Passkit::Pass.find_by(serial_number: params[:serial_number], authentication_token: token)
    return false unless pass&.generator

    last_update = pass.last_update
    response.headers["last-modified"] = last_update.httpdate
    last_update.to_i <= since.to_i
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
