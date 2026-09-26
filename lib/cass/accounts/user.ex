defmodule Cass.Accounts.User do
  @moduledoc """
  A CASS account.

  Milestone 3 Phase 1 keeps the account model deliberately minimal: an email
  address, the hashed password, and the confirmation timestamp. Roles,
  ownership, vendor flags, and profile fields are **not** part of this phase —
  they belong to later Milestone 3 phases (see `docs/data-model.md`).

  ## Password hashing

  Passwords are hashed with PBKDF2-HMAC-SHA512 (`Pbkdf2`, see
  `docs/security.md`). `hashed_password` is `:redact`ed so it can never leak
  through `inspect/1`, crash reports, or log output, and `:password` /
  `:current_password` are virtual and `:redact`ed as well.

  ## Email case handling

  Addresses are normalized (trimmed and downcased) by every changeset that
  casts `:email`, and uniqueness is enforced by a `lower(email)` unique index
  at the database level. Emails are therefore stored exactly once, in a single
  canonical form.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @email_max_length 160
  @password_min_length 12
  # PBKDF2 does not truncate long inputs the way bcrypt does (bcrypt's limit is
  # 72 bytes), so this cap is purely a denial-of-service guard on hashing cost.
  # 128 comfortably accommodates long passphrases.
  @password_max_length 128

  @doc "Maximum accepted email length."
  def email_max_length, do: @email_max_length

  @doc "Minimum accepted password length, in characters."
  def password_min_length, do: @password_min_length

  @doc "Maximum accepted password length, in characters."
  def password_max_length, do: @password_max_length

  schema "cass_users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering an account.

  `Cass.Accounts.register_user/1` composes this with `password_changeset/3`.

  ## Options

    * `:validate_unique` - Set to `false` when you only want to validate the
      format in a form, deferring the uniqueness database round trip until
      submit. Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> normalize_email_change()
    |> validate_email(opts)
  end

  @doc """
  A user changeset for setting or changing a password.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely in
      the database and clears the `:password` field so plaintext passwords are
      never persisted or logged. Set to `false` when the changeset is only used
      to validate a LiveView form. Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc """
  A changeset for changing the email address of an authenticated user.

  In addition to validating the new address, this requires the current
  password, so a hijacked or borrowed session cannot silently take over an
  account by redirecting its mail. The address change itself is only applied
  once the user confirms the new address (see
  `Cass.Accounts.deliver_user_update_email_instructions/3`).

  ## Options

    * `:validate_current_password` - Set to `false` for live form validation.
      Defaults to `true`.
  """
  def email_change_with_password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:current_password])
    |> validate_current_password(opts)
    |> email_changeset(attrs, opts)
  end

  @doc """
  A changeset for changing the password of an authenticated user.

  Requires the current password and is always applied through
  `Cass.Accounts.update_user_password/4`, which revokes every outstanding token
  for the user.

  ## Options

    * `:validate_current_password` - Set to `false` for live form validation.
      Defaults to `true`.
  """
  def password_change_with_current_password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:current_password])
    |> validate_current_password(opts)
    |> password_changeset(attrs, opts)
  end

  @doc """
  Confirms the account by stamping `confirmed_at`.
  """
  def confirm_changeset(user) do
    change(user, confirmed_at: DateTime.utc_now(:second))
  end

  @doc """
  Verifies a password against the stored hash.

  When there is no user, or the user has no password, a dummy verification is
  performed so the time spent on a lookup does not reveal whether the account
  exists (see `CassWeb.UserSessionController.create/2`).
  """
  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end

  @doc "Normalizes a user supplied email address (trim + downcase)."
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalize_email_change(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      _email -> update_change(changeset, :email, &normalize_email/1)
    end
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: @email_max_length)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Cass.Repo)
      |> unique_constraint(:email, name: :cass_users_email_index)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: @password_min_length, max: @password_max_length)
    |> maybe_hash_password(opts)
  end

  defp validate_current_password(changeset, opts) do
    if Keyword.get(opts, :validate_current_password, true) do
      case get_change(changeset, :current_password) do
        current_password when current_password in [nil, ""] ->
          add_error(changeset, :current_password, "can't be blank")

        current_password ->
          if valid_password?(changeset.data, current_password) do
            changeset
          else
            add_error(changeset, :current_password, "is not valid")
          end
      end
    else
      changeset
    end
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing is done here rather than in `Ecto.Changeset.prepare_changes/2`
      # so the database transaction is not held open for the KDF cost.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end
end
