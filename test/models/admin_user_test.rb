# frozen_string_literal: true

require "test_helper"

class AdminUserTest < ActiveSupport::TestCase
  test "first_run? is true when there are no admin users" do
    assert_predicate(AdminUser, :first_run?)
  end

  test "first_run? is false once at least one admin user exists" do
    AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

    refute_predicate(AdminUser, :first_run?)
  end

  test "create_with_password! requires a username" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.create_with_password!(username: "", password: "hunter2hunter2")
    end
  end

  test "create_with_password! requires a non-empty password" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.create_with_password!(username: "michael", password: "")
    end
  end

  test "create_with_password! rejects very short passwords" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.create_with_password!(username: "michael", password: "short")
    end
  end

  test "username is unique" do
    AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

    assert_raises(ActiveRecord::RecordInvalid) do
      AdminUser.create_with_password!(username: "michael", password: "somethingelse12")
    end
  end

  test "password is stored as a bcrypt digest, not plaintext" do
    user = AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

    refute_equal("hunter2hunter2", user.password_digest)
    assert_match(/\A\$2[aby]\$/, user.password_digest)
  end

  test "authenticate returns the user when the password matches" do
    created = AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

    found = AdminUser.authenticate(username: "michael", password: "hunter2hunter2")

    assert_equal(created.id, found.id)
  end

  test "authenticate returns nil when the password is wrong" do
    AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")

    assert_nil(AdminUser.authenticate(username: "michael", password: "wrong-password"))
  end

  test "authenticate returns nil for an unknown username" do
    assert_nil(AdminUser.authenticate(username: "ghost", password: "whatever"))
  end

  test "update_password! replaces the stored digest" do
    user = AdminUser.create_with_password!(username: "michael", password: "hunter2hunter2")
    old_digest = user.password_digest

    user.update_password!("newpassword1234")

    refute_equal(old_digest, user.reload.password_digest)
    assert_nil(AdminUser.authenticate(username: "michael", password: "hunter2hunter2"))
    assert_not_nil(AdminUser.authenticate(username: "michael", password: "newpassword1234"))
  end
end
