defmodule Cass.Repo.Migrations.CreateCassUsersAuthTables do
  use Ecto.Migration

  def change do
    create table(:cass_users) do
      # `email` is stored as a plain string: case-insensitive uniqueness is
      # enforced by the `lower(email)` unique index below (same approach the
      # catalog migration uses for sibling category names) and by the
      # `Cass.Accounts.User` changesets, which always downcase the address.
      add :email, :string, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cass_users, ["lower(email)"], name: :cass_users_email_index)

    create table(:cass_users_tokens) do
      add :user_id, references(:cass_users, on_delete: :delete_all, on_update: :update_all),
        null: false

      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Only the token contexts owned by `Cass.Accounts.UserToken` are allowed.
    # Session tokens are stored verbatim (they are only ever read from the
    # signed session cookie), every other context stores a SHA-256 hash of the
    # token and is bound to the address it was delivered to.
    create constraint(:cass_users_tokens, :cass_users_tokens_context_check,
             check:
               "context in ('session', 'confirm', 'reset_password') or context like 'change:%'"
           )

    create index(:cass_users_tokens, [:user_id])
    create unique_index(:cass_users_tokens, [:context, :token])
  end
end
