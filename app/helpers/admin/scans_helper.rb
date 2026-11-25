module Admin
  module ScansHelper
    # The scanner's mount point: everything app/javascript/scanner needs from
    # the server, on the element scanner_controller.js connects to. The
    # console's status icons ride along as <template>s, since only the server
    # has the helper that draws them.
    def scanner_mount(skin:)
      config = {
        skin: skin,
        eventId: current_event.id,
        userId: current_user.id,
        scanUrl: admin_event_scans_path(current_event),
        searchUrl: search_admin_event_scans_path(current_event),
        nfcEnsureUrl: "/api/v1/events/#{current_event.id}/participant_events/:id/nfc_badge/ensure",
        nfcConfirmUrl: "/admin/events/#{current_event.slug}/participant_events/:id/confirm_nfc_badge",
        nfcWriteOnCheckin: !!(current_event.nfc_badges_enabled? && current_event.nfc_badge_write_on_checkin_enabled?),
        contexts: @scan_contexts.to_h { |context| [ context.id, context.name ] },
        # For checking signed QR codes on the device (see CheckinCode and
        # scanner/ticket.js): the public keys, and the registrations whose
        # tickets no longer count. Ids only; no names reach the device.
        ticketKeys: CheckinCode.public_keys,
        cancelledTickets: CheckinCode.cancelled_registration_ids(current_event)
      }

      tag.div(hidden: true, data: { controller: "scanner", scanner_config_value: config.to_json }) do
        next unless skin.to_sym == :console

        safe_join(%i[success warning error info].map do |tone|
          tag.template(cs_status_icon(tone), data: { scanner_icon: tone })
        end)
      end
    end
  end
end
