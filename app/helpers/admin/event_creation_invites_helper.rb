module Admin
  module EventCreationInvitesHelper
    # status => [ label, Cloudscape status type, original-UI pill classes ]
    EVENT_CREATION_INVITE_STATUSES = {
      "pending" => [ "Sent", :pending, "bg-blue-100 text-blue-800" ],
      "started" => [ "Accepted", :in_progress, "bg-amber-100 text-amber-800" ],
      "completed" => [ "Event created", :success, "bg-green-100 text-green-800" ],
      "expired" => [ "Expired", :stopped, "bg-gray-100 text-gray-600" ],
      "revoked" => [ "Revoked", :stopped, "bg-gray-100 text-gray-600" ]
    }.freeze

    def event_creation_invite_status(invite)
      EVENT_CREATION_INVITE_STATUSES.fetch(invite.status)
    end
  end
end
