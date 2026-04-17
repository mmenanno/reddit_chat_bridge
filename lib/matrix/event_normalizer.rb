# frozen_string_literal: true

module Matrix
  # Immutable record describing one chat-relevant event pulled out of a /sync
  # response. The rest of the bridge — channel index, Discord poster, dedup —
  # only sees these; they never touch the raw Matrix JSON.
  NormalizedEvent = Data.define(
    :room_id,
    :event_id,
    :kind,
    :sender,
    :sender_username,
    :body,
    :origin_server_ts,
    :is_own,
    :is_system,
  ) do
    def own?
      is_own
    end

    def system?
      is_system
    end

    def message?
      kind == :message
    end
  end

  # Turns a raw `/sync` response into the narrow slice the rest of the bridge
  # cares about: one-text-message-at-a-time. Everything else — presence,
  # typing, read markers, power levels, the dozen-odd `com.reddit.*` state
  # events Reddit ships with every room — is filtered out here.
  #
  # Username resolution reads each room's member state (both `state.events`
  # and `timeline.events`, since `m.room.member` arrives through both),
  # preferring Reddit's profile relation when present and falling back to
  # the standard Matrix displayname.
  class EventNormalizer
    REDDIT_SYSTEM_USER_ID = "@t2_1qwk:reddit.com"

    def initialize(own_user_id:)
      @own_user_id = own_user_id
    end

    def normalize(sync_body)
      joined_rooms(sync_body).flat_map { |room_id, room| events_for(room_id, room) }
    end

    private

    def joined_rooms(sync_body)
      sync_body.dig("rooms", "join") || {}
    end

    def events_for(room_id, room)
      usernames = usernames_in(room)
      timeline(room).filter_map { |raw| build_event(room_id, raw, usernames) }
    end

    def timeline(room)
      room.dig("timeline", "events") || []
    end

    def usernames_in(room)
      state = room.dig("state", "events") || []
      timeline_events = timeline(room)
      index = {}

      (state + timeline_events).each do |event|
        next unless event["type"] == "m.room.member"

        user_id = event["state_key"]
        next unless user_id

        username = resolve_username(event)
        index[user_id] = username if username
      end

      index
    end

    def resolve_username(member_event)
      reddit = member_event.dig("unsigned", "m.relations", "com.reddit.profile", "username")
      return reddit if reddit

      member_event.dig("content", "displayname")
    end

    def build_event(room_id, raw, usernames)
      return unless raw["type"] == "m.room.message"

      sender = raw["sender"]
      NormalizedEvent.new(
        room_id: room_id,
        event_id: raw["event_id"],
        kind: :message,
        sender: sender,
        sender_username: usernames[sender],
        body: raw.dig("content", "body"),
        origin_server_ts: raw["origin_server_ts"],
        is_own: sender == @own_user_id,
        is_system: sender == REDDIT_SYSTEM_USER_ID,
      )
    end
  end
end
