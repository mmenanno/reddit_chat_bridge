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

    # Reddit sometimes ships the first message body as part of the invite
    # state. The shape has shifted between Reddit deployments — sometimes
    # a regular `m.room.message`, sometimes one of Reddit's custom event
    # types like `com.reddit.chat.type`. Try the known shapes in priority
    # order; the find_preview_body method falls through to scanning any
    # event with a non-empty content.body so we degrade gracefully across
    # future drifts.
    PREVIEW_EVENT_TYPES = ["m.room.message", "com.reddit.chat.type"].freeze

    def initialize(own_user_id:, notifier: nil, media_resolver: nil, journal: nil)
      @own_user_id = own_user_id
      @notifier = notifier
      @media_resolver = media_resolver
      @journal = journal
    end

    def call(sync_body)
      invites = sync_body.dig("rooms", "invite") || {}
      invites.each { |room_id, payload| upsert_request(room_id, payload) }
    end

    private

    def upsert_request(room_id, payload)
      return if MessageRequest.exists?(matrix_room_id: room_id)
      # Terminated (hidden) rooms stay hidden — ignore any re-invite
      # Reddit sends for the same matrix_room_id. New room_ids from
      # the same counterparty still come through normally.
      return if Room.terminated.exists?(matrix_room_id: room_id)

      events = payload.dig("invite_state", "events") || []
      inviter_id = find_inviter(events)
      preview = find_preview_body(events)
      log_unknown_preview_shape(room_id: room_id, events: events) if preview.nil?

      request = MessageRequest.create!(
        matrix_room_id: room_id,
        inviter_matrix_id: inviter_id,
        inviter_username: find_username(events, inviter_id),
        inviter_avatar_url: find_avatar_url(events, inviter_id),
        preview_body: preview,
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

    def find_preview_body(events)
      PREVIEW_EVENT_TYPES.each do |type|
        body = events.find { |e| e["type"] == type }&.dig("content", "body")
        return body if body.is_a?(String) && !body.empty?
      end
      # Defensive last-resort: any event the inviter sent that has a
      # non-empty content.body string.
      generic = events.find { |e| e.dig("content", "body").is_a?(String) && !e.dig("content", "body").empty? }
      generic&.dig("content", "body")
    end

    # Diagnostic: when the bridge couldn't find a preview body in the
    # invite_state events, journal the event types we did see so the
    # operator can inspect /events and identify the actual shape Reddit
    # is shipping. Limited to the type list — full content would leak
    # the requester's message into the operator's logs.
    def log_unknown_preview_shape(room_id:, events:)
      return unless @journal

      types = events.filter_map { |e| e["type"] }
      @journal.info(
        "Invite for #{room_id} had no extractable preview_body; event types seen: #{types.inspect}",
        source: "invite_handler",
      )
    end

    def member_event_for(events, user_id)
      events.find { |e| e["type"] == "m.room.member" && e["state_key"] == user_id }
    end
  end
end
