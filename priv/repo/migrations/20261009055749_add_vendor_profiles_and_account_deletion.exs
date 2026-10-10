defmodule Cass.Repo.Migrations.AddVendorProfilesAndAccountDeletion do
  use Ecto.Migration

  # Milestone 9 is the seller and account lifecycle: how an account becomes a
  # seller, what buyers see of it, and how it can leave.
  #
  #   * `cass_vendor_profiles` — one optional profile per account. It is both
  #     the **public seller identity** (the `display_name` a product card shows
  #     instead of a handle guessed from an email address) and the **onboarding
  #     application** (`status`). An account applies by creating a `pending`
  #     profile; an admin approves it, which is also the only thing that grants
  #     the `:vendor` role. A `:rejected` profile can be edited and resubmitted,
  #     which is why the owner can write the row but never the status.
  #
  #     The `user_id` is unique (one profile per account) and `:restrict`
  #     (a profile is protected history, like ownership itself), and `status`
  #     is a closed vocabulary mirrored by a CHECK constraint, matching the
  #     product-type and role patterns.
  #
  #   * `cass_users.deleted_at` — account deletion is a **deactivation**. Order,
  #     fulfillment, entitlement, and favorite rows all reference an account and
  #     are `:restrict`, so a hard delete could never preserve a receipt; and a
  #     soft delete is what lets the storefront keep refusing to serve a deleted
  #     account while its history survives. The row stays, the credentials are
  #     scrubbed in `Cass.Accounts.delete_user/1`, and the timestamp makes the
  #     account refusable at login and on session resolution.
  def change do
    create table(:cass_vendor_profiles) do
      add :user_id, references(:cass_users, on_delete: :restrict), null: false
      add :display_name, :string, null: false
      add :business_name, :string
      add :bio, :string
      add :website, :string
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cass_vendor_profiles, [:user_id])
    create index(:cass_vendor_profiles, [:status])

    create constraint(:cass_vendor_profiles, :cass_vendor_profiles_status_check,
             check: "status in ('pending', 'approved', 'rejected')"
           )

    alter table(:cass_users) do
      add :deleted_at, :utc_datetime
    end

    create index(:cass_users, [:deleted_at])
  end
end
