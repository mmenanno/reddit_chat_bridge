# frozen_string_literal: true

require "test_helper"
require "matrix/client"
require "admin/actions"

module Admin
  class ActionsTest < ActiveSupport::TestCase
    NEW_TOKEN = "fresh_token_value"
    NEW_USER = "@t2_self:reddit.com"

    def setup
      super
      @built_with = []
      @probe_client = Matrix::Client.new(access_token: NEW_TOKEN)
      factory = lambda { |token|
        @built_with << token
        @probe_client
      }
      @actions = Admin::Actions.new(matrix_client_factory: factory)
    end

    # ---- reauth ----

    test "reauth probes the new token via whoami before saving" do
      @probe_client.expects(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN, user_id: NEW_USER)

      assert_equal([NEW_TOKEN], @built_with)
    end

    test "reauth persists the token and user_id on probe success" do
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN, user_id: NEW_USER)

      assert_equal(NEW_TOKEN, AuthState.access_token)
      assert_equal(NEW_USER, AuthState.user_id)
    end

    test "reauth marks auth state healthy on success" do
      AuthState.mark_failure!("earlier failure")
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      @actions.reauth(access_token: NEW_TOKEN, user_id: NEW_USER)

      refute_predicate(AuthState, :paused?)
    end

    test "reauth returns :ok on success" do
      @probe_client.stubs(:whoami).returns("user_id" => NEW_USER)

      assert_equal(:ok, @actions.reauth(access_token: NEW_TOKEN, user_id: NEW_USER))
    end

    test "reauth propagates Matrix::TokenError without saving the bad token" do
      @probe_client.stubs(:whoami).raises(Matrix::TokenError, "M_UNKNOWN_TOKEN")
      AuthState.update_token!(access_token: "existing", user_id: "@t2_old:reddit.com")

      assert_raises(Matrix::TokenError) do
        @actions.reauth(access_token: NEW_TOKEN, user_id: NEW_USER)
      end

      assert_equal("existing", AuthState.access_token)
    end

    # ---- resync ----

    test "resync clears the next_batch token" do
      SyncCheckpoint.advance!("some_batch")

      @actions.resync

      assert_nil(SyncCheckpoint.next_batch_token)
    end

    test "resync returns :ok" do
      assert_equal(:ok, @actions.resync)
    end
  end
end
