defmodule Mix.Tasks.Cass.Accounts.CreateAdminTest do
  @moduledoc """
  Tests for the admin bootstrap task.

  Not async: the task reads `Mix.env/0` and the `CASS_ADMIN_PASSWORD`
  environment variable, both of which are global.
  """
  use Cass.DataCase, async: false

  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Accounts.User
  alias Mix.Tasks.Cass.Accounts.CreateAdmin

  @password "correct horse battery staple"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  describe "mix cass.accounts.create_admin" do
    test "registers the account and grants the :admin role" do
      CreateAdmin.run(["--email", "new-admin@example.com", "--password", @password])

      user = Accounts.get_user_by_email("new-admin@example.com")

      assert Accounts.list_user_roles(user) == [:admin]
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "new-admin@example.com"
      assert message =~ ":admin role"
    end

    test "reads the password from CASS_ADMIN_PASSWORD" do
      System.put_env("CASS_ADMIN_PASSWORD", @password)
      on_exit(fn -> System.delete_env("CASS_ADMIN_PASSWORD") end)

      CreateAdmin.run(["--email", "env-admin@example.com"])

      user = Accounts.get_user_by_email("env-admin@example.com")
      assert Accounts.list_user_roles(user) == [:admin]
    end

    test "grants the role to an existing account without touching its password" do
      user = user_fixture()

      CreateAdmin.run(["--email", user.email, "--password", "a completely different passphrase"])

      assert Accounts.get_user_by_email(user.email).id == user.id
      assert Accounts.list_user_roles(user) == [:admin]
      assert User.valid_password?(user, valid_user_password())
    end

    test "keeps the roles the account already had" do
      user = user_fixture() |> role_fixture(:vendor)

      CreateAdmin.run(["--email", user.email])

      assert Accounts.list_user_roles(user) == [:admin, :vendor]
    end

    test "is idempotent" do
      CreateAdmin.run(["--email", "twice@example.com", "--password", @password])
      CreateAdmin.run(["--email", "twice@example.com", "--password", @password])

      user = Accounts.get_user_by_email("twice@example.com")
      assert Accounts.list_user_roles(user) == [:admin]
      assert Repo.aggregate(Cass.Accounts.UserRole, :count) == 1
    end

    test "requires an email" do
      assert_raise Mix.Error, ~r/--email/, fn -> CreateAdmin.run(["--password", @password]) end
    end

    test "requires a password only when the account does not exist yet" do
      assert_raise Mix.Error, ~r/password is required/, fn ->
        CreateAdmin.run(["--email", "no-password@example.com"])
      end

      user = user_fixture()
      CreateAdmin.run(["--email", user.email])

      assert Accounts.list_user_roles(user) == [:admin]
    end

    test "reports a password that fails validation without creating the account" do
      assert_raise Mix.Error, ~r/should be at least 12 character/, fn ->
        CreateAdmin.run(["--email", "weak@example.com", "--password", "short"])
      end

      assert Accounts.get_user_by_email("weak@example.com") == nil
      assert Repo.aggregate(Cass.Accounts.UserRole, :count) == 0
    end

    test "resolves an address that differs only in case to the same account" do
      user = user_fixture(%{email: "taken@example.com"})

      CreateAdmin.run(["--email", "TAKEN@example.com", "--password", @password])

      assert Accounts.get_user_by_email("taken@example.com").id == user.id
      assert Accounts.list_user_roles(user) == [:admin]
      assert Repo.aggregate(User, :count) == 1
    end

    test "refuses to run with MIX_ENV=prod without --force" do
      with_mix_env(:prod, fn ->
        assert_raise Mix.Error, ~r/refusing to create an admin with MIX_ENV=prod/, fn ->
          CreateAdmin.run(["--email", "prod-admin@example.com", "--password", @password])
        end

        assert Accounts.get_user_by_email("prod-admin@example.com") == nil
      end)
    end

    test "runs with MIX_ENV=prod when --force is given" do
      with_mix_env(:prod, fn ->
        CreateAdmin.run(["--email", "prod-admin@example.com", "--password", @password, "--force"])

        user = Accounts.get_user_by_email("prod-admin@example.com")
        assert Accounts.list_user_roles(user) == [:admin]
      end)
    end

    test "prints nothing sensitive" do
      CreateAdmin.run(["--email", "quiet@example.com", "--password", @password])

      assert_received {:mix_shell, :info, [message]}
      refute message =~ @password
    end
  end

  defp with_mix_env(env, fun) do
    original = Mix.env()
    Mix.env(env)

    try do
      fun.()
    after
      Mix.env(original)
    end
  end
end
