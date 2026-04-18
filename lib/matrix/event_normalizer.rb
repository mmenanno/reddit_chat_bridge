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
    :sender_avatar_url,
    :body,
    :origin_server_ts,
    :is_own,
    :is_system,
    :media_url,
    :media_mime,
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

    def media?
      !media_url.nil? && !media_url.empty?
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
    MEDIA_MSGTYPES = ["m.image", "m.file", "m.video", "m.audio"].freeze

    def initialize(own_user_id:, media_resolver: nil)
      @own_user_id = own_user_id
      @media_resolver = media_resolver
    end

    def normalize(sync_body)
      joined_rooms(sync_body).flat_map { |room_id, room| events_for(room_id, room) }
    end

    private

    def joined_rooms(sync_body)
      sync_body.dig("rooms", "join") || {}
    end

    def events_for(room_id, room)
      usernames, avatars = member_lookup_for(room)
      timeline(room).filter_map { |raw| build_event(room_id, raw, usernames, avatars) }
    end

    def timeline(room)
      room.dig("timeline", "events") || []
    end

    def member_lookup_for(room)
      state = room.dig("state", "events") || []
      timeline_events = timeline(room)
      usernames = {}
      avatars = {}

      (state + timeline_events).each do |event|
        next unless event["type"] == "m.room.member"

        user_id = event["state_key"]
        next unless user_id

        username = resolve_username(event)
        usernames[user_id] = username if username

        avatar = resolve_avatar(event)
        avatars[user_id] = avatar if avatar
      end

      [usernames, avatars]
    end

    def resolve_username(member_event)
      reddit = member_event.dig("unsigned", "m.relations", "com.reddit.profile", "username")
      return reddit if reddit

      member_event.dig("content", "displayname")
    end

    # Reddit ships both a stable mxc avatar on content.avatar_url and, for
    # some accounts, a pre-rendered snoovatar URL on the profile relation.
    # Prefer the relation's snoovatar (https, cache-friendly) and fall back
    # to the mxc, which MediaResolver will turn into an https URL.
    def resolve_avatar(member_event)
      snoovatar = member_event.dig("unsigned", "m.relations", "com.reddit.profile", "snoovatar_url")
      return snoovatar if snoovatar.to_s.start_with?("http")

      member_event.dig("content", "avatar_url")
    end

    def build_event(room_id, raw, usernames, avatars)
      return unless raw["type"] == "m.room.message"

      sender = raw["sender"]
      msgtype = raw.dig("content", "msgtype")
      media_url, media_mime = resolve_media(raw) if MEDIA_MSGTYPES.include?(msgtype)

      NormalizedEvent.new(
        room_id: room_id,
        event_id: raw["event_id"],
        kind: media_url ? :media : :message,
        sender: sender,
        sender_username: usernames[sender],
        sender_avatar_url: resolve_avatar_url(avatars[sender]),
        body: raw.dig("content", "body"),
        origin_server_ts: raw["origin_server_ts"],
        is_own: sender == @own_user_id,
        is_system: sender == REDDIT_SYSTEM_USER_ID,
        media_url: media_url,
        media_mime: media_mime,
      )
    end

    def resolve_avatar_url(raw)
      return if raw.nil? || raw.empty?
      return raw if raw.start_with?("http")
      return unless @media_resolver

      @media_resolver.resolve(raw)
    end

    def resolve_media(raw)
      return unless @media_resolver

      mxc = raw.dig("content", "url")
      return unless mxc

      [@media_resolver.resolve(mxc), raw.dig("content", "info", "mimetype")]
    end
  end
end
