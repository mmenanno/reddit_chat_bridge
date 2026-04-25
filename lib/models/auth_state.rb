# frozen_string_literal: true

require "active_support/message_encryptor"
require "active_support/key_generator"
require "base64"
require "json"

# Singleton row describing the bridge's current Matrix authentication.
#
# The SQLite database holds exactly one `auth_state` row; callers reach it
# through class-level helpers rather than `AuthState.find(id)`. Storing auth
# state in the database (instead of an env var) means the operator can
# rotate the Matrix access token from the web UI without a container
# restart — the whole point of the `/auth` page.
#
# The Reddit cookie jar (source of all future Matrix JWT refreshes) is
# stored encrypted with a key derived from AppConfig's session_secret.
# The host's filesystem permissions already cover the whole state volume,
# so this is defence-in-depth rather than a security boundary on its own.
# It does mean a stray database dump in isolation doesn't hand an
# attacker a usable Reddit session.
class AuthState < ApplicationRecord
  self.table_name = "auth_state"

  COOKIE_JAR_SALT = "reddit_cookie_jar/v1"
  REDDIT_SESSION_WARNING_WINDOW = 7.days

  class << self
    def current
      first || create!
    end

    def update_token!(access_token:, user_id:)
      row = current
      row.update!(access_token: access_token, user_id: user_id)
      mark_ok!
    end

    def mark_ok!
      current.update!(
        paused: false,
        paused_reason: nil,
        last_ok_at: Time.current,
        consecutive_failures: 0,
        last_error: nil,
      )
    end

    def mark_failure!(reason)
      row = current
      row.update!(
        paused: true,
        paused_reason: "token_rejected",
        consecutive_failures: row.consecutive_failures + 1,
        last_error: reason.to_s,
      )
    end

    # Operator-initiated pause. Flips the same `paused` flag the supervisor
    # gates on (`lib/bridge/supervisor.rb`), but tags the reason so the UI
    # can distinguish a deliberate pause from an auth failure. last_ok_at
    # and consecutive_failures are sync-health telemetry, not auth state,
    # so they're left alone.
    def pause_by_operator!
      current.update!(paused: true, paused_reason: "operator", last_error: nil)
    end

    # Mirror of pause_by_operator!. Doesn't stamp last_ok_at — the next
    # real /sync iteration will do that authentically via mark_ok!.
    def resume_by_operator!
      current.update!(paused: false, paused_reason: nil, last_error: nil)
    end

    def paused?
      current.paused?
    end

    def paused_by_operator?
      row = current
      row.paused? && row.paused_reason == "operator"
    end

    def access_token
      current.access_token
    end

    def user_id
      current.user_id
    end

    # ---- Reddit session / cookie jar ----

    def store_reddit_session!(cookie_jar)
      encrypted = encryptor.encrypt_and_sign(cookie_jar)
      current.update!(
        reddit_cookie_jar: encrypted,
        reddit_session_expires_at: extract_reddit_session_expiry(cookie_jar),
      )
    end

    def reddit_cookie_jar
      encrypted = current.reddit_cookie_jar
      return if encrypted.to_s.empty?

      encryptor.decrypt_and_verify(encrypted)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage,
           ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def reddit_session_expires_at
      current.reddit_session_expires_at
    end

    def reddit_session_expiring_soon?(within: REDDIT_SESSION_WARNING_WINDOW)
      expires_at = reddit_session_expires_at
      return false unless expires_at

      expires_at - Time.current < within
    end

    def access_token_expires_at
      exp = decode_jwt_exp(current.access_token)
      return unless exp

      Time.at(exp.to_f).utc
    end

    def access_token_expiring_soon?(within: 1.hour)
      expires_at = access_token_expires_at
      return false unless expires_at

      expires_at - Time.current < within
    end

    private

    def encryptor
      secret = AppConfig.fetch("session_secret", "")
      raise("AuthState encryption requires session_secret in AppConfig") if secret.to_s.empty?

      key = ActiveSupport::KeyGenerator.new(secret).generate_key(COOKIE_JAR_SALT, 32)
      ActiveSupport::MessageEncryptor.new(key)
    end

    def extract_reddit_session_expiry(cookie_jar)
      match = cookie_jar.to_s.match(/(?:\A|;\s*)reddit_session=([^;]+)/)
      return unless match

      Time.at(decode_jwt_exp(match[1]).to_f).utc if decode_jwt_exp(match[1])
    rescue StandardError
      nil
    end

    def decode_jwt_exp(jwt)
      payload = decode_jwt_payload(jwt)
      return unless payload.is_a?(Hash)

      payload["exp"]
    end

    def decode_jwt_payload(jwt)
      encoded = jwt.to_s.split(".").fetch(1, nil)
      return unless encoded

      padded = encoded.tr("-_", "+/")
      padded += "=" * ((4 - (padded.length % 4)) % 4)
      JSON.parse(padded.unpack1("m"))
    rescue JSON::ParserError
      nil
    end
  end
end
