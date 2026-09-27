defmodule Cass.Accounts.RolesTest do
  @moduledoc """
  Tests for the role foundation: the closed role vocabulary, granting and
  revoking, and the scope that carries the result into authorization checks.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Accounts.User
  alias Cass.Accounts.UserRole

  describe "the role vocabulary" do
    test "is exactly :admin and :vendor, with no :customer" do
      assert Accounts.roles() == [:admin, :vendor]
      refute :customer in Accounts.roles()
    end

    test "parses atoms and strings, normalizing case and surrounding space" do
      assert UserRole.parse(:admin) == {:ok, :admin}
      assert UserRole.parse("admin") == {:ok, :admin}
      assert UserRole.parse("  Vendor ") == {:ok, :vendor}
      assert UserRole.parse("VENDOR") == {:ok, :vendor}
    end

    test "refuses anything outside the vocabulary" do
      assert UserRole.parse("superuser") == :error
      assert UserRole.parse("") == :error
      assert UserRole.parse(:superuser) == :error
      assert UserRole.parse(%{}) == :error
      assert UserRole.parse(["admin"]) == :error
      refute UserRole.valid?("root")
    end
  end

  describe "list_user_roles/1" do
    test "is empty for a new account" do
      assert Accounts.list_user_roles(user_fixture()) == []
    end

    test "returns granted roles as atoms in a stable order" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)
      :ok = Accounts.grant_user_role(user, :admin)

      assert Accounts.list_user_roles(user) == [:admin, :vendor]
    end

    test "user_has_role?/2 answers for a single role" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)

      assert Accounts.user_has_role?(user, :vendor)
      refute Accounts.user_has_role?(user, :admin)
    end

    test "user_has_role?/2 accepts the string form of a role" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)

      assert Accounts.user_has_role?(user, "vendor")
      assert Accounts.user_has_role?(user, " Vendor ")
      refute Accounts.user_has_role?(user, "admin")
    end

    test "user_has_role?/2 is false for a role outside the vocabulary" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :admin)

      refute Accounts.user_has_role?(user, "superuser")
      refute Accounts.user_has_role?(user, :superuser)
      refute Accounts.user_has_role?(user, nil)
    end
  end

  describe "grant_user_role/2" do
    test "grants a role" do
      user = user_fixture()

      assert :ok = Accounts.grant_user_role(user, :admin)
      assert Accounts.list_user_roles(user) == [:admin]
    end

    test "accepts the string form of a role" do
      user = user_fixture()

      assert :ok = Accounts.grant_user_role(user, "vendor")
      assert Accounts.list_user_roles(user) == [:vendor]
    end

    test "grants several roles to the same account" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :admin)
      :ok = Accounts.grant_user_role(user, :vendor)

      assert Accounts.list_user_roles(user) == [:admin, :vendor]
    end

    test "is idempotent" do
      user = user_fixture()

      assert :ok = Accounts.grant_user_role(user, :vendor)
      assert :ok = Accounts.grant_user_role(user, :vendor)

      assert Repo.aggregate(UserRole, :count) == 1
      assert Accounts.list_user_roles(user) == [:vendor]
    end

    test "rejects a role outside the vocabulary without writing anything" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.grant_user_role(user, :superuser)
      assert %{role: ["is not a known role"]} = errors_on(changeset)
      assert Accounts.list_user_roles(user) == []
      assert Repo.aggregate(UserRole, :count) == 0
    end

    test "rejects a nil role" do
      assert {:error, changeset} = Accounts.grant_user_role(user_fixture(), nil)
      assert %{role: ["can't be blank"]} = errors_on(changeset)
    end

    test "cannot name a different account through the attributes" do
      user = user_fixture()
      other = user_fixture()

      # The only role argument is the role itself: there is no path from a
      # caller-supplied map to the `user_id` the row is written against.
      changeset =
        UserRole.changeset(%UserRole{user_id: user.id}, %{role: :admin, user_id: other.id})

      assert Ecto.Changeset.get_change(changeset, :user_id) == nil

      {:ok, user_role} = Repo.insert(changeset)
      assert user_role.user_id == user.id
      assert Accounts.list_user_roles(other) == []
    end
  end

  describe "revoke_user_role/2" do
    test "revokes a granted role" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)

      assert :ok = Accounts.revoke_user_role(user, :vendor)
      assert Accounts.list_user_roles(user) == []
    end

    test "keeps the other roles" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :admin)
      :ok = Accounts.grant_user_role(user, :vendor)

      assert :ok = Accounts.revoke_user_role(user, :vendor)
      assert Accounts.list_user_roles(user) == [:admin]
    end

    test "is idempotent for a role the user does not hold" do
      user = user_fixture()

      assert :ok = Accounts.revoke_user_role(user, :admin)
      assert :ok = Accounts.revoke_user_role(user, :admin)
      assert Accounts.list_user_roles(user) == []
    end

    test "reports an unknown role instead of silently doing nothing" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)

      assert {:error, :invalid_role} = Accounts.revoke_user_role(user, "superuser")
      assert Accounts.list_user_roles(user) == [:vendor]
    end

    test "only touches the given user" do
      user = user_fixture()
      other = user_fixture()
      :ok = Accounts.grant_user_role(user, :vendor)
      :ok = Accounts.grant_user_role(other, :vendor)

      assert :ok = Accounts.revoke_user_role(user, :vendor)
      assert Accounts.list_user_roles(user) == []
      assert Accounts.list_user_roles(other) == [:vendor]
    end
  end

  describe "the database" do
    test "rejects a role outside the vocabulary" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      assert_raise Ecto.ConstraintError, ~r/cass_user_roles_role_check/, fn ->
        %UserRole{user_id: user.id, role: "superuser", inserted_at: now}
        |> Repo.insert!()
      end

      assert Accounts.list_user_roles(user) == []
    end

    test "rejects the same role twice" do
      user = user_fixture()
      now = DateTime.utc_now(:second)

      %UserRole{user_id: user.id, role: "admin", inserted_at: now} |> Repo.insert!()

      assert_raise Ecto.ConstraintError, ~r/cass_user_roles_user_id_role_index/, fn ->
        %UserRole{user_id: user.id, role: "admin", inserted_at: now} |> Repo.insert!()
      end
    end

    test "removes a user's roles when the account is deleted" do
      user = user_fixture()
      :ok = Accounts.grant_user_role(user, :admin)

      assert Repo.aggregate(UserRole, :count) == 1
      Repo.delete!(user)
      assert Repo.aggregate(UserRole, :count) == 0
    end
  end

  describe "Scope" do
    test "a guest scope has no user and no roles" do
      scope = Scope.for_user(nil)

      assert scope.user == nil
      assert scope.roles == MapSet.new()
      refute Scope.authenticated?(scope)
      refute Scope.admin?(scope)
      refute Scope.vendor?(scope)
    end

    test "an account with no roles is authenticated but neither admin nor vendor" do
      scope = Scope.for_user(user_fixture())

      assert Scope.authenticated?(scope)
      refute Scope.admin?(scope)
      refute Scope.vendor?(scope)
    end

    test "carries the roles read from the database" do
      scope = Scope.for_user(user_with_role_fixture(:admin))

      assert Scope.authenticated?(scope)
      assert Scope.admin?(scope)
      refute Scope.vendor?(scope)
      assert Scope.role?(scope, :admin)
      refute Scope.role?(scope, :vendor)
    end

    test "an admin is not implicitly a vendor" do
      assert Scope.vendor?(Scope.for_user(admin_fixture())) == false
    end

    test "a vendor is not implicitly an admin" do
      assert Scope.admin?(Scope.for_user(vendor_fixture())) == false
    end

    test "carries several roles at once" do
      user = user_fixture() |> role_fixture(:admin) |> role_fixture(:vendor)
      scope = Scope.for_user(user)

      assert Scope.admin?(scope)
      assert Scope.vendor?(scope)
      assert scope.roles == MapSet.new([:admin, :vendor])
    end

    test "is rebuilt from the database, so a revoke applies to the next scope" do
      user = admin_fixture()

      assert Scope.admin?(Scope.for_user(user)) == true

      :ok = Accounts.revoke_user_role(user, :admin)

      # The same `%User{}` struct, held by a caller, carries no roles of its own:
      # nothing is cached in the user row or in the session.
      assert Scope.admin?(Scope.for_user(user)) == false
    end

    test "answers false for a nil scope, so callers need no guest guard" do
      refute Scope.authenticated?(nil)
      refute Scope.admin?(nil)
      refute Scope.vendor?(nil)
      refute Scope.role?(nil, :admin)
    end

    test "can be built from a preloaded list of roles" do
      scope = Scope.for_user(%User{id: 1}, [:admin, :vendor])

      assert scope.roles == MapSet.new([:admin, :vendor])
      assert Scope.admin?(scope)
      assert Scope.vendor?(scope)
    end
  end
end
