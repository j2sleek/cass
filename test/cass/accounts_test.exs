defmodule Cass.AccountsTest do
  @moduledoc """
  Tests for the Accounts context: registration, credential verification, email
  confirmation, session tokens, email changes, and password resets.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Accounts.{User, UserToken}

  describe "register_user/1" do
    test "requires email and password to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{
               email: ["can't be blank"],
               password: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates email and password when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid", password: "short"})

      assert %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "validates maximum values for email and password for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long, password: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
      assert "should be at most 128 character(s)" in errors_on(changeset).password
    end

    test "validates email uniqueness (case insensitive)" do
      %{email: email} = user_fixture()

      {:error, changeset} =
        Accounts.register_user(%{email: String.upcase(email), password: valid_user_password()})

      assert "has already been taken" in errors_on(changeset).email

      # Now try with the lower cased one too, to check that email case is ignored.
      {:error, changeset} =
        Accounts.register_user(%{email: String.downcase(email), password: valid_user_password()})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_binary(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end

    test "never stores the plaintext password" do
      password = valid_user_password()
      {:ok, user} = Accounts.register_user(valid_user_attributes(password: password))

      refute user.hashed_password == password
      assert reloaded = Accounts.get_user!(user.id)
      refute reloaded.hashed_password == password
      assert is_nil(reloaded.password)
    end

    test "accepts an email with mixed case and surrounding whitespace" do
      {:ok, user} =
        Accounts.register_user(%{
          email: "  MiXeD@Example.COM ",
          password: valid_user_password()
        })

      assert user.email == "mixed@example.com"
    end
  end

  describe "password hashing" do
    test "the stored hash is PBKDF2 and verifies" do
      user = user_fixture()
      assert user.hashed_password =~ "pbkdf2-sha512"
      assert User.valid_password?(user, valid_user_password())
      refute User.valid_password?(user, "wrong password")
    end

    test "hashed_password is redacted from inspect" do
      user = user_fixture()
      refute inspect(user) =~ user.hashed_password
    end

    test "an unknown user never verifies a password" do
      refute User.valid_password?(%User{}, valid_user_password())
      refute User.valid_password?(%User{hashed_password: nil}, valid_user_password())
    end
  end

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end

    test "normalizes the lookup" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(String.upcase(user.email))
      assert %User{id: ^id} = Accounts.get_user_by_email(" #{user.email} ")
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "whatever")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "wrong")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "accepts a differently cased email" do
      user = user_fixture()

      assert %User{} =
               Accounts.get_user_by_email_and_password(
                 String.upcase(user.email),
                 valid_user_password()
               )
    end
  end

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "stores only a hash of the token, bound to the address", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, raw_token} = Base.url_decode64(token, padding: false)
      stored = user_token(user, "confirm")
      assert stored.user_id == user.id
      assert stored.sent_to == user.email
      assert stored.token == :crypto.hash(:sha256, raw_token)
      refute stored.token == raw_token
    end
  end

  describe "confirm_user/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.confirmed_at != user.confirmed_at
      assert Accounts.get_user!(user.id).confirmed_at
    end

    test "consumes the token so it cannot be replayed", %{token: token} do
      assert {:ok, _user} = Accounts.confirm_user(token)
      assert {:error, :invalid_token} = Accounts.confirm_user(token)
    end

    test "does not confirm with invalid token" do
      assert {:error, :invalid_token} = Accounts.confirm_user("nope")
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      expire_tokens(user, ["confirm"])

      assert {:error, :invalid_token} = Accounts.confirm_user(token)
      refute Accounts.get_user!(user.id).confirmed_at
    end

    test "keeps existing sessions of the user", %{user: user, token: token} do
      session_token = Accounts.generate_user_session_token(user)

      assert {:ok, _user} = Accounts.confirm_user(token)
      assert Accounts.get_user_by_session_token(session_token)
    end
  end

  describe "session tokens" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "generates a token that resolves to the user", %{user: user, token: token} do
      assert {%User{id: id}, inserted_at} = Accounts.get_user_by_session_token(token)
      assert id == user.id
      assert %DateTime{} = inserted_at
    end

    test "does not accept unknown or malformed tokens" do
      refute Accounts.get_user_by_session_token("nope")
      refute Accounts.get_user_by_session_token(nil)
      refute Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32))
    end

    test "rejects an expired session token", %{user: user, token: token} do
      expire_tokens(user, ["session"])

      refute Accounts.get_user_by_session_token(token)
    end

    test "delete_user_session_token/1 ends only that session", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      other_token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token)
      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
      assert Accounts.get_user_by_session_token(other_token)
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      user = user_fixture()
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(user)
      refute changeset.valid?
      assert %{current_password: ["can't be blank"]} = errors_on(changeset)
    end

    test "allows changing the email with a valid current password" do
      user = user_fixture()
      password = valid_user_password()

      changeset =
        Accounts.change_user_email(user, %{
          "current_password" => password,
          "email" => unique_user_email()
        })

      assert changeset.valid?
    end

    test "invalidates the email when the current password is wrong" do
      user = user_fixture()

      changeset =
        Accounts.change_user_email(user, %{
          "current_password" => "invalid_value",
          "email" => unique_user_email()
        })

      refute changeset.valid?
      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "the email is not applied until it is confirmed" do
      user = user_fixture()
      email = unique_user_email()

      changeset =
        Accounts.change_user_email(user, %{
          "current_password" => valid_user_password(),
          "email" => email
        })

      assert changeset.valid?
      refute Accounts.get_user_by_email(email)
      assert Accounts.get_user!(user.id).email != email
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      user = user_fixture()
      new_user = %{user | email: unique_user_email()}

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(new_user, user.email, url)
        end)

      %{user: user, new_user: new_user, token: token}
    end

    test "stores a hash of the token in the context of the current address", %{
      user: user,
      new_user: new_user,
      token: token
    } do
      {:ok, raw_token} = Base.url_decode64(token, padding: false)
      stored = user_token(user, "change:#{user.email}")
      assert stored.user_id == user.id
      assert stored.sent_to == new_user.email
      assert stored.token == :crypto.hash(:sha256, raw_token)
    end
  end

  describe "update_user_email/2" do
    setup do
      user = user_fixture()
      new_user = %{user | email: unique_user_email()}

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(new_user, user.email, url)
        end)

      %{user: user, new_user: new_user, token: token}
    end

    test "updates the email with a valid token", %{
      user: user,
      new_user: new_user,
      token: token
    } do
      assert {:ok, updated_user} = Accounts.update_user_email(user, token)
      assert updated_user.email == new_user.email
      assert Accounts.get_user_by_email(new_user.email).id == updated_user.id
    end

    test "the link is single use", %{user: user, token: token} do
      assert {:ok, _user} = Accounts.update_user_email(user, token)
      assert {:error, :invalid_token} = Accounts.update_user_email(user, token)
    end

    test "does not update the email with invalid token", %{user: user} do
      assert {:error, :invalid_token} = Accounts.update_user_email(user, "oops")
      assert Accounts.get_user!(user.id).email == user.email
    end

    test "a token issued for one account cannot be used on another", %{user: user, token: token} do
      other_user = user_fixture()
      assert {:error, :invalid_token} = Accounts.update_user_email(other_user, token)
      assert Accounts.get_user!(other_user.id).email == other_user.email
      assert Accounts.get_user!(user.id).email == user.email
    end
  end

  describe "update_user_password/4" do
    setup do
      %{user: user_fixture()}
    end

    test "validates the current password" do
      user = user_fixture()

      {:error, changeset} =
        Accounts.update_user_password(user, "invalid", %{
          password: valid_user_password()
        })

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "validates the new password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "short",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "updates the password and revokes other sessions", %{user: user} do
      current_password = valid_user_password()
      session_token = Accounts.generate_user_session_token(user)
      other_session_token = Accounts.generate_user_session_token(user)
      new_password = "new valid password"

      assert {:ok, {updated_user, revoked}} =
               Accounts.update_user_password(user, current_password, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      assert is_nil(updated_user.password)
      assert %{hashed_password: hashed} = updated_user
      assert is_binary(hashed)
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
      assert Enum.any?(revoked, &(&1.token == session_token))
      assert Enum.any?(revoked, &(&1.token == other_session_token))
      refute Accounts.get_user_by_session_token(other_session_token)
      refute Accounts.get_user_by_session_token(session_token)
    end

    test "keeps the session the change was made from when asked", %{user: user} do
      current_session = Accounts.generate_user_session_token(user)
      other_session = Accounts.generate_user_session_token(user)
      new_password = "new valid password"

      assert {:ok, {_user, revoked}} =
               Accounts.update_user_password(
                 user,
                 valid_user_password(),
                 %{password: new_password, password_confirmation: new_password},
                 keep_session_token: current_session
               )

      assert [%UserToken{context: "session", token: revoked_token}] = revoked
      assert revoked_token == other_session
      assert Accounts.get_user_by_session_token(current_session)
      refute Accounts.get_user_by_session_token(other_session)
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "stores a hashed, address-bound token", %{user: user, token: token} do
      {:ok, raw_token} = Base.url_decode64(token, padding: false)
      stored = user_token(user, "reset_password")
      assert stored.user_id == user.id
      assert stored.sent_to == user.email
      assert stored.token == :crypto.hash(:sha256, raw_token)
    end
  end

  describe "get_user_by_valid_reset_password_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "returns the user and token for a valid token", %{user: user, token: token} do
      assert {%User{id: id}, %UserToken{}} =
               Accounts.get_user_by_valid_reset_password_token(token)

      assert id == user.id
    end

    test "returns nil for an invalid or expired token", %{user: user, token: token} do
      assert Accounts.get_user_by_valid_reset_password_token("nope") == nil

      expire_tokens(user, ["reset_password"])

      assert Accounts.get_user_by_valid_reset_password_token(token) == nil
    end

    test "does not accept a token from another context", %{user: user} do
      {encoded, _} = UserToken.build_session_token(user)
      assert Accounts.get_user_by_valid_reset_password_token(encoded) == nil
    end
  end

  describe "reset_user_password/3" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "resets the password with a valid token", %{user: user, token: token} do
      new_password = "new valid password"

      assert {:ok, {updated_user, _tokens}} =
               Accounts.reset_user_password(user, token, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
      assert is_nil(updated_user.password)
    end

    test "the token cannot be used twice", %{user: user, token: token} do
      new_password = "new valid password"

      assert {:ok, _} =
               Accounts.reset_user_password(user, token, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      assert {:error, :invalid_token} =
               Accounts.reset_user_password(user, token, %{
                 password: "another valid password",
                 password_confirmation: "another valid password"
               })
    end

    test "revokes every session of the user", %{user: user, token: token} do
      session_token = Accounts.generate_user_session_token(user)
      new_password = "new valid password"

      assert {:ok, {_user, revoked}} =
               Accounts.reset_user_password(user, token, %{
                 password: new_password,
                 password_confirmation: new_password
               })

      assert Enum.any?(revoked, &(&1.token == session_token))
      refute Accounts.get_user_by_session_token(session_token)
      assert Accounts.get_user_by_valid_reset_password_token(token) == nil
    end

    test "does not reset the password with an invalid token", %{user: user} do
      assert {:error, :invalid_token} =
               Accounts.reset_user_password(user, "nope", %{
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "does not reset the password with a token issued to another account", %{token: token} do
      other_user = user_fixture()

      assert {:error, :invalid_token} =
               Accounts.reset_user_password(other_user, token, %{
                 password: valid_user_password(),
                 password_confirmation: valid_user_password()
               })

      assert Accounts.get_user_by_email_and_password(other_user.email, valid_user_password())
    end

    test "requires the password to be valid", %{user: user, token: token} do
      assert {:error, changeset} =
               Accounts.reset_user_password(user, token, %{
                 password: "short",
                 password_confirmation: "another"
               })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)

      # The token is not consumed by a failed attempt.
      assert {%User{}, %UserToken{}} = Accounts.get_user_by_valid_reset_password_token(token)
    end
  end

  # Captures the token out of the URL the notifier was handed, so the tests can
  # assert on what was actually delivered.
  defp extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  defp user_token(%User{id: user_id}, context) do
    Repo.one!(from t in UserToken, where: t.user_id == ^user_id and t.context == ^context)
  end

  defp expire_tokens(%User{id: user_id}, contexts) do
    Repo.update_all(
      from(t in UserToken, where: t.user_id == ^user_id and t.context in ^contexts),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -30, :day)]
    )
  end
end
