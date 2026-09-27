defmodule CassWeb.UserAuthorizationTest do
  @moduledoc """
  Tests for the role guards built on `Cass.Accounts.Scope`: the controller
  plugs and the LiveView `on_mount` hooks.

  No route uses the role guards yet (Milestone 3 Phase 2 ships the mechanism and
  the vendor and admin areas come later), so these exercise the guards the way a
  router would call them, through the real scope resolution in the `:browser`
  pipeline.
  """
  use CassWeb.ConnCase, async: true

  alias Cass.Accounts.Scope
  alias CassWeb.UserAuth

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, CassWeb.Endpoint.config(:secret_key_base))
      |> Phoenix.ConnTest.init_test_session(%{})

    %{conn: conn}
  end

  describe "require_authenticated_user/2" do
    test "lets a signed-in customer through", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(user_fixture())
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end

    test "lets an admin through", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(admin_fixture())
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "redirects a guest to the log in page and halts", %{conn: conn} do
      conn =
        conn
        |> guest()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
    end

    test "remembers where the guest was headed", %{conn: conn} do
      conn =
        conn
        |> guest()
        |> Map.put(:path_info, ["catalog", "products", "some-product"])
        |> UserAuth.require_authenticated_user([])

      assert get_session(conn, :user_return_to) == "/catalog/products/some-product"
    end

    test "does not remember a return path for a non-GET request", %{conn: conn} do
      conn =
        conn
        |> guest()
        |> fetch_flash()
        |> Map.put(:method, "POST")
        |> UserAuth.require_authenticated_user([])

      refute get_session(conn, :user_return_to)
    end
  end

  describe "require_admin_user/2" do
    test "lets an admin through", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(admin_fixture())
        |> UserAuth.require_admin_user([])

      refute conn.halted
    end

    test "refuses a signed-in customer", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(user_fixture())
        |> UserAuth.require_admin_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not authorized"
    end

    test "refuses a vendor, which is not implicitly an admin", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(vendor_fixture())
        |> UserAuth.require_admin_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "sends a guest to the log in page", %{conn: conn} do
      conn =
        conn
        |> guest()
        |> UserAuth.require_admin_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "must log in"
    end

    test "does not store a return path for a signed-in user who is refused", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(user_fixture())
        |> UserAuth.require_admin_user([])

      refute get_session(conn, :user_return_to)
    end
  end

  describe "require_vendor_user/2" do
    test "lets a vendor through", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(vendor_fixture())
        |> UserAuth.require_vendor_user([])

      refute conn.halted
    end

    test "lets an admin who is also a vendor through", %{conn: conn} do
      user = user_fixture() |> role_fixture(:admin) |> role_fixture(:vendor)

      conn =
        conn
        |> signed_in_as(user)
        |> UserAuth.require_vendor_user([])

      refute conn.halted
    end

    test "refuses a plain admin", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(admin_fixture())
        |> UserAuth.require_vendor_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/settings"
    end

    test "refuses a signed-in customer", %{conn: conn} do
      conn =
        conn
        |> signed_in_as(user_fixture())
        |> UserAuth.require_vendor_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/settings"
    end
  end

  describe "on_mount(:mount_current_scope, ...)" do
    test "loads the roles of the session user", %{conn: conn} do
      token = conn |> log_in_user(admin_fixture()) |> get_session(:user_token)

      assert {:cont, socket} = mount_hook(:mount_current_scope, %{"user_token" => token})
      assert Scope.admin?(socket.assigns.current_scope)
    end

    test "assigns a guest scope without a session token" do
      assert {:cont, socket} = mount_hook(:mount_current_scope, %{})
      assert socket.assigns.current_scope == %Scope{}
    end

    test "does not rebuild a scope that is already assigned" do
      socket = socket_with_scope(Scope.for_user(admin_fixture()))

      assert {:cont, ^socket} = UserAuth.on_mount(:mount_current_scope, %{}, %{}, socket)
    end
  end

  describe "on_mount(:require_authenticated, ...)" do
    test "continues for a signed-in customer" do
      assert {:cont, _socket} = mount_hook_for(:require_authenticated, user_fixture())
    end

    test "continues for an admin" do
      assert {:cont, _socket} = mount_hook_for(:require_authenticated, admin_fixture())
    end

    test "halts a guest and sends them to the log in page" do
      assert {:halt, socket} = mount_hook(:require_authenticated, %{})

      assert socket.redirected == {:redirect, %{to: ~p"/users/log-in", status: 302}}
      assert socket.assigns.flash["error"] =~ "must log in"
    end
  end

  describe "on_mount(:require_admin, ...)" do
    test "continues for an admin" do
      assert {:cont, socket} = mount_hook_for(:require_admin, admin_fixture())
      assert Scope.admin?(socket.assigns.current_scope)
    end

    test "halts a guest and sends them to the log in page" do
      assert {:halt, socket} = mount_hook(:require_admin, %{})

      assert socket.redirected == {:redirect, %{to: ~p"/users/log-in", status: 302}}
      assert socket.assigns.flash["error"] =~ "must log in"
    end

    test "halts a signed-in customer and sends them to their settings page" do
      assert {:halt, socket} = mount_hook_for(:require_admin, user_fixture())

      assert socket.redirected == {:redirect, %{to: ~p"/users/settings", status: 302}}
      assert socket.assigns.flash["error"] =~ "not authorized"
    end
  end

  describe "on_mount(:require_vendor, ...)" do
    test "continues for a vendor" do
      assert {:cont, socket} = mount_hook_for(:require_vendor, vendor_fixture())
      assert Scope.vendor?(socket.assigns.current_scope)
    end

    test "halts a guest" do
      assert {:halt, socket} = mount_hook(:require_vendor, %{})

      assert socket.redirected == {:redirect, %{to: ~p"/users/log-in", status: 302}}
    end

    test "halts a plain admin, who is not implicitly a vendor" do
      assert {:halt, socket} = mount_hook_for(:require_vendor, admin_fixture())

      assert socket.redirected == {:redirect, %{to: ~p"/users/settings", status: 302}}
      assert socket.assigns.flash["error"] =~ "not authorized"
    end
  end

  # Builds a conn whose `current_scope` was resolved the way the `:browser`
  # pipeline resolves it: a session token in, a scope with the database roles
  # out.
  defp signed_in_as(conn, user) do
    conn
    |> log_in_user(user)
    |> UserAuth.fetch_current_scope_for_user([])
    |> fetch_flash()
  end

  defp guest(conn), do: conn |> UserAuth.fetch_current_scope_for_user([]) |> fetch_flash()

  defp mount_hook(hook, session), do: UserAuth.on_mount(hook, %{}, session, socket())

  defp mount_hook_for(hook, user) do
    session = %{"user_token" => Cass.Accounts.generate_user_session_token(user)}
    mount_hook(hook, session)
  end

  defp socket, do: socket_with_scope(nil)

  defp socket_with_scope(scope) do
    assigns = %{__changed__: %{}, flash: %{}}
    assigns = if scope, do: Map.put(assigns, :current_scope, scope), else: assigns

    %Phoenix.LiveView.Socket{
      assigns: assigns,
      endpoint: CassWeb.Endpoint,
      router: CassWeb.Router,
      private: %{live_temp: %{}}
    }
  end
end
