# frozen_string_literal: true

module Matrix
  # Called from the SyncLoop on every iteration, this turns
  # `/sync → rooms.invite` payloads into MessageRequest rows — one row
  # per room the operator hasn't seen yet. Used-to-be: the SyncLoop
  # blindly auto-joined every invite; that matched Reddit's old
  # "anyone can DM" model but broke when message-request UX became
  # the default on reddit.com.
  #
  # Deliberately idempotent: invites re-appear on /sync every tick
  # until the operator approves or declines, so we dedupe on
  # matrix_room_id. Extraction is defensive — a malformed invite_state
  # produces a row with as much info as we could find (even nil) rather
  # than raising and stalling the sync loop.
  class InviteHandler
    MEMBERSHIP_INVITE = "invite"

    def initialize(own_user_id:, notifier: nil, media_resolver: nil)
      @own_user_id = own_user_id
      @notifier = notifier
      @media_resolver = media_resolver
    end

    def call(sync_body)
      invites = sync_body.dig("rooms", "invite") || {}
      invites.each { |room_id, payload| upsert_request(room_id, payload) }
    end

    private

    def upsert_request(room_id, payload)
      return if MessageRequest.exists?(matrix_room_id: room_id)

      events = payload.dig("invite_state", "events") || []
      inviter_id = find_inviter(events)
      request = MessageRequest.create!(
        matrix_room_id: room_id,
        inviter_matrix_id: inviter_id,
        inviter_username: find_username(events, inviter_id),
        inviter_avatar_url: find_avatar_url(events, inviter_id),
        preview_body: find_preview_body(events),
      )
      @notifier&.notify!(request)
    rescue ActiveRecord::RecordNotUnique
      # Race: another /sync tick beat us to the insert. Safe to ignore.
      nil
    end

    # The inviter is the `sender` of the m.room.member event that marked
    # us (own_user_id) as `membership: "invite"`. Fall back to the first
    # member event's sender if we can't find a self-targeted one — rare,
    # but better than nil.
    def find_inviter(events)
      self_invite = events.find do |e|
        e["type"] == "m.room.member" &&
          e["state_key"] == @own_user_id &&
          e.dig("content", "membership") == MEMBERSHIP_INVITE
      end
      return self_invite["sender"] if self_invite

      member_event = events.find { |e| e["type"] == "m.room.member" }
      member_event&.dig("sender")
    end

    # Member events for the inviter carry their displayname — prefer
    # Reddit's profile relation (authoritative) then displayname.
    def find_username(events, inviter_id)
      return unless inviter_id

      event = member_event_for(events, inviter_id)
      return unless event

      event.dig("unsigned", "m.relations", "com.reddit.profile", "username") ||
        event.dig("content", "displayname")
    end

    def find_avatar_url(events, inviter_id)
      return unless inviter_id

      event = member_event_for(events, inviter_id)
      return unless event

      snoovatar = event.dig("unsigned", "m.relations", "com.reddit.profile", "snoovatar_url")
      return snoovatar if snoovatar.to_s.start_with?("http")

      mxc = event.dig("content", "avatar_url")
      return unless mxc && @media_resolver

      @media_resolver.resolve(mxc)
    end

    # Reddit sometimes ships the first message body as part of the invite
    # state via an `m.room.message` event. When it's there, surfacing it
    # lets the operator approve/decline without joining first.
    def find_preview_body(events)
      msg = events.find { |e| e["type"] == "m.room.message" }
      msg&.dig("content", "body")
    end

    def member_event_for(events, user_id)
      events.find { |e| e["type"] == "m.room.member" && e["state_key"] == user_id }
    end
  end
end
