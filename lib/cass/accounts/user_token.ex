defmodule Cass.Accounts.UserToken do
  @moduledoc """
  Tokens used for sessions, email confirmation, email changes, and password
  resets.

  ## Storage rules

    * `session` tokens are stored verbatim. They are only ever read from the
      signed (and HttpOnly) session cookie, so they cannot be recovered from a
      database dump alone, and storing them lets individual sessions be revoked
      server-side.
    * every other context stores a SHA-256 **hash** of the token together with
      the address (`sent_to`) the token was delivered to. The raw token only
      exists in the URL handed to the user. A database leak therefore does not
      hand out working confirmation or reset links, and changing the email
      invalidates tokens issued to the previous address.
    * tokens are random 32-byte values from `:crypto.strong_rand_bytes/1`.

  Validity is always checked on read, both against the stored hash and against
  `inserted_at` expiry, and consumed tokens are deleted (single use).
  """
  use Ecto.Schema

  import Ecto.Query, warn: false

  alias Cass.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32
  @session_validity_in_days 14
  @confirm_validity_in_days 7
  @change_email_validity_in_days 7
  @reset_password_validity_in_hours 1

  schema "cass_users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    belongs_to :user, Cass.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "How long a session token stays valid."
  def session_validity_in_days, do: @session_validity_in_days

  @doc "How long an email confirmation token stays valid."
  def confirm_validity_in_days, do: @confirm_validity_in_days

  @doc "How long an email change token stays valid."
  def change_email_validity_in_days, do: @change_email_validity_in_days

  @doc "How long a password reset token stays valid."
  def reset_password_validity_in_hours, do: @reset_password_validity_in_hours

  @doc """
  Generates a token that is stored in a signed place, such as the session
  cookie. Because it is signed, it does not need to be hashed.

  Storing session tokens in the database — even though Phoenix already provides
  a signed session cookie — is what makes individual sessions revocable and
  expirable.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Checks if the session token is valid and returns its underlying lookup query.

  The query returns `{user, token_inserted_at}` when the token is still valid. A
  deactivated account (`cass_users.deleted_at` set) is excluded, so a session
  that survived the deletion transaction can never resolve to a live user.
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        where: is_nil(user.deleted_at),
        select: {user, token.inserted_at}

    {:ok, query}
  end

  @doc """
  Builds a confirmation token and its hash.

  The raw token is what gets delivered to the user; the hash is what gets
  stored. The token is bound to the address it was issued for.
  """
  def build_email_confirmation_token(user) do
    build_hashed_token(user, "confirm", user.email)
  end

  @doc """
  Checks if the confirmation token is valid and returns its underlying lookup
  query. The query returns `{user, token}` when the token is valid.
  """
  def verify_email_confirmation_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "confirm"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@confirm_validity_in_days, "day"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Builds a token for an email address change, bound to the address the change
  is requested from.
  """
  def build_email_change_token(user, current_email) do
    build_hashed_token(user, "change:#{current_email}", user.email)
  end

  @doc """
  Checks if the email change token is valid and returns its underlying lookup
  query. The context must always start with `"change:"`.
  """
  def verify_email_change_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(^@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Builds a password reset token and its hash, bound to the account's address.
  """
  def build_reset_password_token(user) do
    build_hashed_token(user, "reset_password", user.email)
  end

  @doc """
  Checks if the password reset token is valid and returns its underlying lookup
  query. The query returns `{user, token}` when the token is valid and has not
  expired (after #{@reset_password_validity_in_hours} hour).
  """
  def verify_reset_password_token_query(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, "reset_password"),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^@reset_password_validity_in_hours, "hour"),
            where: token.sent_to == user.email,
            select: {user, token}

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Deletes every token of the given contexts for a user.

  Used to revoke sessions (and all other outstanding links) after a sensitive
  change such as a password reset.
  """
  def revoke_user_tokens(user_id, contexts) when is_list(contexts) do
    Cass.Repo.delete_all(
      from t in UserToken, where: t.user_id == ^user_id and t.context in ^contexts
    )
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_id: user.id
     }}
  end

  defp by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
