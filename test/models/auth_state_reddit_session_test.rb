# frozen_string_literal: true

require "test_helper"

class AuthStateRedditSessionTest < ActiveSupport::TestCase
  # `reddit_session` is a JWT with an `exp` claim ~6 months out. For these
  # tests any syntactically-valid JWT with a known exp claim works.
  PAYLOAD_B64 = Base64.urlsafe_encode64('{"sub":"t2_abc","exp":1791775617,"jti":"x"}').tr("=", "")
  REDDIT_SESSION_JWT = "eyJhbGciOiJSUzI1NiJ9.#{PAYLOAD_B64}.sig".freeze
  COOKIE_JAR = "reddit_session=#{REDDIT_SESSION_JWT}; loid=000000abc; token_v2=stale_jwt_we_ignore".freeze

  setup do
    # Encryption requires a session_secret in AppConfig — the same value the
    # web app persists on first boot. Stub one for the model tests.
    AppConfig.set("session_secret", "test_secret_for_encryption_at_rest")
  end

  test "reddit_cookie_jar starts nil" do
    assert_nil(AuthState.reddit_cookie_jar)
  end

  test "store_reddit_session! persists the cookie jar and returns it decrypted" do
    AuthState.store_reddit_session!(COOKIE_JAR)

    assert_equal(COOKIE_JAR, AuthState.reddit_cookie_jar)
  end

  test "store_reddit_session! encrypts the cookie jar at rest" do
    AuthState.store_reddit_session!(COOKIE_JAR)

    raw_column = AuthState.current.read_attribute_before_type_cast(:reddit_cookie_jar)

    refute_equal(COOKIE_JAR, raw_column)
    refute_includes(raw_column, "reddit_session")
  end

  test "store_reddit_session! extracts and persists reddit_session_expires_at" do
    AuthState.store_reddit_session!(COOKIE_JAR)

    assert_equal(Time.at(1_791_775_617).utc, AuthState.reddit_session_expires_at.utc)
  end

  test "store_reddit_session! leaves reddit_session_expires_at nil when the cookie has no reddit_session JWT" do
    AuthState.store_reddit_session!("loid=abc; edgebucket=x")

    assert_nil(AuthState.reddit_session_expires_at)
  end

  test "reddit_session_expiring_in? returns true when within the threshold" do
    AuthState.store_reddit_session!(COOKIE_JAR)
    Time.stubs(:current).returns(Time.at(1_791_775_617 - 3.days.to_i))

    assert_predicate(AuthState, :reddit_session_expiring_soon?)
  end

  test "reddit_session_expiring_in? returns false with more than a week remaining" do
    AuthState.store_reddit_session!(COOKIE_JAR)
    Time.stubs(:current).returns(Time.at(1_791_775_617 - 60.days.to_i))

    refute_predicate(AuthState, :reddit_session_expiring_soon?)
  end

  test "reddit_session_expiring_in? is false when no cookie is stored" do
    refute_predicate(AuthState, :reddit_session_expiring_soon?)
  end

  test "decrypting after session_secret rotates fails gracefully with nil" do
    AuthState.store_reddit_session!(COOKIE_JAR)
    AppConfig.set("session_secret", "a_completely_different_secret_now")

    assert_nil(AuthState.reddit_cookie_jar)
  end
end
