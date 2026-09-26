defmodule Cass.Accounts do
  @moduledoc """
  The Accounts context: registration, authentication, session tokens, email
  confirmation, email changes, and password resets.

  ## Design decisions

  * **Password hashing** — PBKDF2-HMAC-SHA512 via `Pbkdf2` (`pbkdf2_elixir`),
    the `--hashing-lib pbkdf2` option of `mix phx.gen.auth`. See
    `docs/security.md` for the full rationale. Passwords are hashed in
    `Cass.Accounts.User` changesets and never stored, returned, or logged in
    plaintext; `hashed_password` is `:redact`ed.
  * **Password rules** — length only (12 to 128 characters). No composition
    rules (uppercase/digit/symbol) are imposed: they measurably reduce
    security while pushing users toward predictable patterns. The upper bound
    is a hashing-cost guard, not a bcrypt-style truncation limit.
  * **Email identity** — addresses are normalized to lowercase by the
    changesets and unique per database (`lower(email)` unique index). Login,
    confirmation, and password-reset lookups all go through the same
    normalization.
  * **No enumeration** — `get_user_by_email_and_password/2` runs a dummy hash
    verification for unknown addresses, and the login form answers with a
    single generic "Invalid email or password" error. Password reset requests
    always answer with the same neutral message, and confirmation/reset token
    verification returns a generic failure that does not disclose whether an
    account exists.
  * **Tokens** — see `Cass.Accounts.UserToken`. Non-session tokens are stored
    as SHA-256 hashes, expire, and are single use (consumed tokens are deleted
    inside the same transaction that consumes them).
  * **Token revocation** — a password change or reset deletes every token of
    the user, so all other sessions and links stop working immediately. The
    single exception is the session the password change was made from: it is
    kept (`:keep_session_token`) so the user is not signed out of the browser
    they are already using, and only the other sessions are dropped.
  * **Server-side identity** — nothing here accepts a user id from a caller.
    Authentication always resolves a `%User{}` from a server-held session
    token; `Cass.Accounts.Scope` is the only carrier of caller identity, and
    it is built by `CassWeb.UserAuth`.

  Return conventions: `{:ok, record}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.{User, UserNotifier, UserToken}
  alias Cass.Repo

  ## Database getters

  @doc """
  Gets a user by email address (case-insensitive), or `nil`.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: User.normalize_email(email))
  end

  @doc """
  Gets a user by email address and password, or `nil`.

  Unknown addresses still pay for a dummy hash verification, so the response
  time does not disclose whether an account exists.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password), do: user
  end

  @doc """
  Fetches a user by id, raising if it does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user with an email address and a password.

  The password is validated and hashed; duplicate addresses are rejected both
  by the changeset's uniqueness validation and by the database constraint.

  ## Examples

      iex> register_user(%{email: "foo@example.com", password: "hello world!"})
      {:ok, %User{}}

      iex> register_user(%{email: "bad"})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> User.password_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for registration forms.

  The password is **not** hashed here, so the changeset can be used for live
  form validation.

  ## Examples

      iex> change_user_registration(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
    user
    |> User.email_changeset(attrs, opts)
    |> User.password_changeset(attrs, Keyword.put_new(opts, :hash_password, false))
  end

  @doc """
  Delivers account confirmation instructions to the given user.

  The raw token is only ever returned through the URL function.
  """
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_confirmation_token(user)

    Repo.insert!(user_token)
    UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
  end

  @doc """
  Generates a token that will be delivered in a confirmation link.

  Useful for tests and for callers that hand the link over themselves. The
  token is single use, as with `deliver_user_confirmation_instructions/2`.
  """
  def generate_user_confirmation_token(%User{} = user) do
    {encoded_token, user_token} = UserToken.build_email_confirmation_token(user)
    Repo.insert!(user_token)
    encoded_token
  end

  @doc """
  Confirms a user account from a token.

  Confirmation consumes exactly the token it was issued with, so the link is
  single use and a replayed or leaked link cannot be used to authenticate. Any
  other outstanding session of the account is deliberately left alone: opening
  a confirmation link must not sign the user out.

  Returns `{:error, :invalid_token}` for unknown, expired, or already-used
  tokens without disclosing which case it was.

  ## Examples

      iex> confirm_user(token)
      {:ok, %User{}}

      iex> confirm_user("nope")
      {:error, :invalid_token}

  """
  def confirm_user(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_confirmation_token_query(token),
         {%User{} = user, user_token} <- Repo.one(query),
         {:ok, user} <- Repo.transact(fn -> confirm_user_multi(user, user_token) end) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp confirm_user_multi(user, user_token) do
    with {:ok, user} <- Repo.update(User.confirm_changeset(user)),
         {_count, _} <-
           Repo.delete_all(from t in UserToken, where: t.id == ^user_token.id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the email of an authenticated
  user. The current password is required.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.email_change_with_password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token is valid, the email is updated and every token issued for the
  previous address is deleted.
  """
  def update_user_email(%User{} = user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_email_change_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})) do
        UserToken.revoke_user_tokens(user.id, [context])
        {:ok, user}
      else
        _ -> {:error, :invalid_token}
      end
    end)
  end

  @doc """
  Delivers instructions to change the user email to a new address.

  The change is only applied once the new address is confirmed.
  """
  def deliver_user_update_email_instructions(
        %User{} = user,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_change_token(user, current_email)

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Generates a token that will be delivered in an email change link.

  The `new_email` argument is the pending address. The token is bound to both
  the current and the pending address, so it cannot be replayed after the
  change has been applied.
  """
  def generate_user_change_email_token(%User{} = user, new_email) when is_binary(new_email) do
    pending_user = %{user | email: new_email}
    {encoded_token, user_token} = UserToken.build_email_change_token(pending_user, user.email)
    Repo.insert!(user_token)
    encoded_token
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing a password. The current password
  is required.
  """
  def change_user_password(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.password_change_with_current_password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password after verifying the current one.

  Every token of the user is deleted, so all other sessions are logged out and
  pending confirmation/reset links stop working.

  ## Options

    * `:keep_session_token` — the session token (from the *signed* session, never
      from client parameters) to keep alive. It is used by the settings page so
      the user who just changed their password is not logged out of the browser
      they are using, while every other session is revoked. Password resets do
      not pass it and therefore drop all sessions.

  Returns the updated user together with the list of revoked tokens, so the
  caller can disconnect the LiveViews that were using them.

  ## Examples

      iex> update_user_password(user, current_password, %{password: "new password"})
      {:ok, {%User{}, [tokens]}}

      iex> update_user_password(user, "wrong", %{password: "new password"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(%User{} = user, current_password, attrs, opts \\ []) do
    password = attr(attrs, "password")
    password_confirmation = attr(attrs, "password_confirmation")

    user
    |> User.password_change_with_current_password_changeset(%{
      current_password: current_password,
      password: password,
      password_confirmation: password_confirmation
    })
    |> update_user_password_changeset(Keyword.get(opts, :keep_session_token))
  end

  defp attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, String.to_existing_atom(key))
    end
  end

  defp update_user_password_changeset(changeset, keep_session_token) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = expirable_tokens(user, keep_session_token)

        Repo.delete_all(from t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  defp expirable_tokens(%User{id: user_id}, nil), do: Repo.all_by(UserToken, user_id: user_id)

  defp expirable_tokens(%User{id: user_id}, token) do
    Repo.all_by(UserToken, user_id: user_id)
    |> Enum.reject(&match?(%UserToken{context: "session", token: ^token}, &1))
  end

  ## Session

  @doc """
  Generates a session token, to be stored in the signed session cookie.
  """
  def generate_user_session_token(%User{} = user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns `{user, token_inserted_at}` for a valid, unexpired session token, or
  `nil`.

  Anything that is not a binary (including `nil`) is rejected without a query.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def get_user_by_session_token(_token), do: nil

  @doc """
  Deletes the session token with the given value, ending that session.
  """
  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(from UserToken, where: [token: ^token, context: "session"])
    :ok
  end

  def delete_user_session_token(_token), do: :ok

  ## Password reset

  @doc """
  Delivers instructions to reset a forgotten password to the given user.

  Callers that start from an address must resolve the user first
  (`get_user_by_email/1`) and always answer with the same neutral message, so
  the flow never discloses whether an account exists.
  """
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_reset_password_token(user)

    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Generates a reset password token, to be handed out in a reset link.

  Useful for tests and for callers that build the link themselves. The token is
  single use and expires like any other reset token.
  """
  def generate_user_reset_password_token(%User{} = user) do
    {token, user_token} = UserToken.build_reset_password_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Returns `{user, user_token}` when the reset token is valid and unexpired, else
  `nil`.

  The returned user is the account the token was issued for — never a user id
  taken from the request.
  """
  def get_user_by_valid_reset_password_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_reset_password_token_query(token),
         {%User{} = user, user_token} <- Repo.one(query) do
      {user, user_token}
    else
      _ -> nil
    end
  end

  @doc """
  Resets the password of a user with a valid reset token.

  The token is verified here (so the caller cannot pair a user with somebody
  else's token) and consumed in the same transaction that stores the new hash,
  which also revokes every other token of that account. A reset link is
  therefore strictly single use.
  """
  def reset_user_password(%User{} = user, token, attrs) when is_binary(token) do
    case get_user_by_valid_reset_password_token(token) do
      {%User{id: user_id}, _user_token} ->
        if user_id == user.id do
          user
          |> User.password_changeset(attrs)
          |> update_user_password_changeset(nil)
        else
          {:error, :invalid_token}
        end

      nil ->
        {:error, :invalid_token}
    end
  end
end
