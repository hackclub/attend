class EventPolicy < ApplicationPolicy
  def index?
    user.global_admin? || user.event_role_assignments.exists? || user.series_role_assignments.exists?
  end

  def show?
    user.global_admin? || user.can_access_event?(record)
  end

  # Series members can create events inside their own series; the record must
  # carry the target event_series_id so membership can be checked here.
  def create?
    return true if user.global_admin?

    record.is_a?(Event) && record.event_series_id.present? && user.series_member_for_event?(record)
  end

  def update?
    user.global_admin? || user.can_access_event?(record)
  end

  def select?
    user.global_admin? || user.can_access_event?(record)
  end

  # Who may add, re-role and remove staff: global admins, this event's own
  # admins, and — through User#event_admin_for? — members of its series. Ops,
  # limited, safeguarding leads and read-only staff cannot (mirrors
  # Admin::EventStaffController#require_event_admin_access).
  def manage_staff?
    user.global_admin? || user.event_admin_for?(record)
  end

  # Adding people to an event is an event admin's call — every other role's
  # ROLE_DETAILS say "cannot add or remove participants". Covers the invite
  # form, the CSV import, and the API's POST /participants for signed-in users.
  # Series owners and organizers count as event admins (User#event_admin_for?).
  def invite_participants?
    user.global_admin? || user.event_admin_for?(record)
  end

  # An event API token can send invitations without any role check, so minting
  # one is the same privilege as inviting: event admins only. Narrower than
  # manage_integrations? on purpose — ops can run the rest of the page.
  def manage_api_tokens?
    user.global_admin? || user.event_admin_for?(record)
  end

  def regenerate_api_key?
    manage_api_tokens?
  end

  # The Integrations & API page: waiver and custom document templates, DocuSeal
  # field mappings, Airtable sync, Slack, and event API tokens. Changing any of
  # these changes what participants are asked to sign or who can pull their
  # data, so it is held to the ops bar — event admins, ops, and series members.
  # Limited (local organizers), safeguarding leads, and read-only staff can
  # withdraw participants and work the event without it.
  def manage_integrations?
    user.ops_for?(record)
  end

  def destroy?
    user.global_admin?
  end

  def withdraw?
    user.global_admin?
  end

  def manage_rooming?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited]) ||
      user.series_member_for_event?(record)
  end

  def manage_groups?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited]) ||
      user.series_member_for_event?(record)
  end

  # "limited" is included: the controller redacts dates of birth and addresses
  # out of the payload for it (see Api::V1::ParticipantsController#include_pii?).
  # "read_only" still gets nothing.
  def api_participants?
    return true if user.global_admin?

    user.event_role_assignments.exists?(event: record, role: %w[event_admin ops limited safeguarding_lead]) ||
      user.series_member_for_event?(record)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.global_admin?
        scope.all
      else
        scope.where(id: user.event_role_assignments.select(:event_id))
             .or(scope.where(event_series_id: user.series_role_assignments.select(:event_series_id)))
      end
    end
  end
end
