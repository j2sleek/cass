defmodule Cass.Repo.Migrations.CreateCassUserRoles do
  use Ecto.Migration

  def change do
    # Roles live in a join table rather than a boolean/enum column on
    # `cass_users`: a user can hold several at once (an admin who also sells),
    # and a join table keeps the `Cass.Accounts.UserRole` schema the only place
    # that has to know which roles exist. The database constrains that set
    # independently of the application (see the check constraint below), so a
    # typo in application code cannot invent a new role.
    create table(:cass_user_roles) do
      add :user_id, references(:cass_users, on_delete: :delete_all, on_update: :update_all),
        null: false

      # Stored as the lowercase string form of the role atom (`:admin` ->
      # "admin"), mirroring how `cass_users_tokens.context` stores its
      # validated vocabulary.
      add :role, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Only the roles owned by `Cass.Accounts.UserRole` are allowed. Adding a
    # role therefore requires a migration, exactly like the token contexts in
    # the Phase 1 auth migration.
    create constraint(:cass_user_roles, :cass_user_roles_role_check,
             check: "role in ('admin', 'vendor')"
           )

    # One row per user and role: granting a role twice is a no-op rather than a
    # duplicate. This is also the conflict target that makes
    # `Cass.Accounts.grant_user_role/2` idempotent.
    create unique_index(:cass_user_roles, [:user_id, :role],
             name: :cass_user_roles_user_id_role_index
           )

    # Scope resolution always filters by `user_id` (served by the unique index
    # above); this one is for the operational queries that come with the vendor
    # and admin areas.
    create index(:cass_user_roles, [:role])
  end
end
