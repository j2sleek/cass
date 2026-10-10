defmodule Cass.VendorsTest do
  @moduledoc """
  Tests for the Vendors context: the onboarding application, the admin review
  that approves or rejects it, the role grant that approval performs, and the
  public seller identity a profile provides.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Vendors
  alias Cass.Vendors.VendorProfile

  describe "statuses/0" do
    test "is the closed vocabulary of profile statuses" do
      assert Vendors.statuses() == [:pending, :approved, :rejected]
    end
  end

  describe "get_profile/1 and get_profile_for_user/1" do
    test "a guest has no profile" do
      assert Vendors.get_profile(Scope.for_user(nil)) == nil
      assert Vendors.get_profile(nil) == nil
      assert Vendors.get_profile_for_user(nil) == nil
    end

    test "an account that never applied has no profile" do
      user = user_fixture()

      assert Vendors.get_profile(Scope.for_user(user)) == nil
      assert Vendors.get_profile_for_user(user) == nil
    end

    test "returns the account's profile" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)

      assert Vendors.get_profile(Scope.for_user(user)).id == profile.id
      assert Vendors.get_profile_for_user(user).id == profile.id
    end
  end

  describe "save_profile/2" do
    test "an ordinary account's application is pending" do
      user = user_fixture()

      assert {:ok, %VendorProfile{status: :pending} = profile} =
               Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      assert profile.user_id == user.id
      assert profile.display_name == "Ada's Shop"
    end

    test "a vendor's edits stay approved" do
      user = vendor_fixture()

      assert {:ok, %VendorProfile{status: :approved}} =
               Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})
    end

    test "an account whose vendor role was revoked is pending again" do
      user = vendor_fixture()
      {:ok, _} = Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      :ok = Accounts.revoke_user_role(user, :vendor)

      assert {:ok, %VendorProfile{status: :pending} = updated} =
               Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      # The same profile row was updated, not a second one inserted.
      assert updated.user_id == user.id
      assert Repo.aggregate(VendorProfile, :count) == 1
    end

    test "a guest is refused" do
      assert {:error, :not_authenticated} =
               Vendors.save_profile(Scope.for_user(nil), %{display_name: "Nobody"})

      assert {:error, :not_authenticated} =
               Vendors.save_profile(nil, %{display_name: "Nobody"})

      assert Repo.aggregate(VendorProfile, :count) == 0
    end

    test "a submitted status is ignored, never obeyed" do
      user = user_fixture()
      other = user_fixture()

      assert {:ok, profile} =
               Vendors.save_profile(Scope.for_user(user), %{
                 "display_name" => "Ada's Shop",
                 "status" => "approved",
                 "user_id" => other.id
               })

      assert profile.status == :pending
      assert profile.user_id == user.id
      refute profile.user_id == other.id
    end

    test "requires a display name" do
      assert {:error, changeset} =
               Vendors.save_profile(Scope.for_user(user_fixture()), %{})

      assert %{display_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "bounds the display name" do
      scope = Scope.for_user(user_fixture())

      assert {:error, changeset} = Vendors.save_profile(scope, %{display_name: "a"})
      assert %{display_name: [message]} = errors_on(changeset)
      assert message =~ "at least"

      assert {:error, changeset} =
               Vendors.save_profile(scope, %{display_name: String.duplicate("a", 61)})

      assert %{display_name: [message]} = errors_on(changeset)
      assert message =~ "at most"
    end

    test "accepts only an absolute http(s) website" do
      scope = Scope.for_user(user_fixture())

      assert {:ok, _} =
               Vendors.save_profile(scope, %{
                 display_name: "Ada's Shop",
                 website: "https://ada.example.com"
               })

      assert {:error, changeset} =
               Vendors.save_profile(scope, %{
                 display_name: "Ada's Shop",
                 website: "ada.example.com"
               })

      assert %{website: ["must be an absolute http(s) URL"]} = errors_on(changeset)
    end

    test "editing a rejected profile resubmits it" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)
      admin = admin_fixture()

      assert {:ok, %VendorProfile{status: :rejected}} =
               Vendors.reject_profile(Scope.for_user(admin), profile)

      assert {:ok, %VendorProfile{status: :pending}} =
               Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop, again"})
    end

    test "updates the existing profile rather than inserting a second one" do
      user = user_fixture()
      {:ok, _} = Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      assert {:ok, updated} =
               Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Store"})

      assert updated.display_name == "Ada's Store"
      assert Repo.aggregate(VendorProfile, :count) == 1
    end
  end

  describe "list_profiles/1" do
    test "an admin sees every profile, newest first, with the account preloaded" do
      older = vendor_profile_fixture(nil, %{display_name: "Older Shop"})
      newer = vendor_profile_fixture(nil, %{display_name: "Newer Shop"})

      profiles = Vendors.list_profiles(Scope.for_user(admin_fixture()))

      assert Enum.map(profiles, & &1.id) == [newer.id, older.id]
      assert Enum.all?(profiles, &match?(%Cass.Accounts.User{}, &1.user))
    end

    test "a non-admin sees nothing" do
      vendor_profile_fixture()

      assert Vendors.list_profiles(Scope.for_user(user_fixture())) == []
      assert Vendors.list_profiles(Scope.for_user(vendor_fixture())) == []
      assert Vendors.list_profiles(Scope.for_user(nil)) == []
      assert Vendors.list_profiles(nil) == []
    end
  end

  describe "get_reviewable_profile/2" do
    test "an admin fetches a profile by id or string id" do
      profile = vendor_profile_fixture()
      admin = Scope.for_user(admin_fixture())

      assert Vendors.get_reviewable_profile(admin, profile.id).id == profile.id
      assert Vendors.get_reviewable_profile(admin, to_string(profile.id)).id == profile.id
    end

    test "a non-admin gets nil, and malformed ids are inert" do
      profile = vendor_profile_fixture()

      assert Vendors.get_reviewable_profile(Scope.for_user(vendor_fixture()), profile.id) == nil
      assert Vendors.get_reviewable_profile(Scope.for_user(nil), profile.id) == nil

      admin = Scope.for_user(admin_fixture())
      assert Vendors.get_reviewable_profile(admin, "not-a-number") == nil
      assert Vendors.get_reviewable_profile(admin, 0) == nil
    end
  end

  describe "approve_profile/2" do
    test "marks the profile approved and grants the vendor role" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)

      assert {:ok, %VendorProfile{status: :approved} = approved} =
               Vendors.approve_profile(Scope.for_user(admin_fixture()), profile)

      assert approved.id == profile.id
      assert Accounts.user_has_role?(user, :vendor)
    end

    test "approval is idempotent" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)
      admin = Scope.for_user(admin_fixture())

      assert {:ok, _} = Vendors.approve_profile(admin, profile)

      assert {:ok, %VendorProfile{status: :approved}} =
               Vendors.approve_profile(admin, Repo.get!(VendorProfile, profile.id))

      assert Accounts.list_user_roles(user) == [:vendor]
    end

    test "a non-admin is refused and nothing changes" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)

      assert {:error, :not_authorized} =
               Vendors.approve_profile(Scope.for_user(vendor_fixture()), profile)

      assert {:error, :not_authorized} = Vendors.approve_profile(nil, profile)

      assert Repo.get!(VendorProfile, profile.id).status == :pending
      refute Accounts.user_has_role?(user, :vendor)
    end
  end

  describe "reject_profile/2" do
    test "marks the profile rejected without touching the text" do
      profile = vendor_profile_fixture(nil, %{display_name: "Ada's Shop", bio: "Handmade"})

      assert {:ok, %VendorProfile{status: :rejected} = rejected} =
               Vendors.reject_profile(Scope.for_user(admin_fixture()), profile)

      assert rejected.display_name == "Ada's Shop"
      assert rejected.bio == "Handmade"
    end

    test "does not revoke an already-held vendor role" do
      user = vendor_fixture()
      profile = vendor_profile_fixture(user)

      assert {:ok, _} = Vendors.reject_profile(Scope.for_user(admin_fixture()), profile)
      assert Accounts.user_has_role?(user, :vendor)
    end

    test "a non-admin is refused" do
      profile = vendor_profile_fixture()

      assert {:error, :not_authorized} =
               Vendors.reject_profile(Scope.for_user(vendor_fixture()), profile)

      assert {:error, :not_authorized} = Vendors.reject_profile(nil, profile)
      assert Repo.get!(VendorProfile, profile.id).status == :pending
    end
  end

  describe "public_name/1" do
    test "returns the display name of an approved profile" do
      user = vendor_fixture()
      {:ok, _} = Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      loaded = Repo.preload(user, :vendor_profile)
      assert Vendors.public_name(loaded) == "Ada's Shop"
    end

    test "returns nil for a pending or rejected profile" do
      pending_user = user_fixture()
      vendor_profile_fixture(pending_user, %{display_name: "Pending Shop"})
      assert Vendors.public_name(Repo.preload(pending_user, :vendor_profile)) == nil

      rejected_user = user_fixture()
      rejected = vendor_profile_fixture(rejected_user)
      {:ok, _} = Vendors.reject_profile(Scope.for_user(admin_fixture()), rejected)

      assert Vendors.public_name(Repo.preload(rejected_user, :vendor_profile)) == nil
    end

    test "returns nil for an account with no profile, an unloaded profile, or no user" do
      assert Vendors.public_name(user_fixture()) == nil

      assert Vendors.public_name(%Cass.Accounts.User{
               vendor_profile: %Ecto.Association.NotLoaded{}
             }) == nil

      assert Vendors.public_name(nil) == nil
      assert Vendors.public_name("not a user") == nil
    end

    test "returns nil for an approved profile with an empty name" do
      user = vendor_fixture()
      {:ok, _} = Vendors.save_profile(Scope.for_user(user), %{display_name: "Ada's Shop"})

      # Force an empty name past validation to exercise the guard directly.
      Repo.update_all(
        from(p in VendorProfile, where: p.user_id == ^user.id),
        set: [display_name: ""]
      )

      assert Vendors.public_name(Repo.preload(user, :vendor_profile)) == nil
    end
  end
end
