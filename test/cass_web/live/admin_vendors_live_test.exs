defmodule CassWeb.AdminVendorsLiveTest do
  @moduledoc """
  Tests for the admin vendor review dashboard (`/admin/vendors`): who may reach
  it, and that approving or rejecting an application has the right effect on the
  profile and the account's roles.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Repo
  alias Cass.Vendors
  alias Cass.Vendors.VendorProfile

  describe "authorization" do
    test "redirects a guest to the login page" do
      assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/admin/vendors")
      assert to =~ "/users/log-in"
    end

    test "redirects a signed-in non-admin away" do
      for user <- [user_fixture(), vendor_fixture()] do
        conn = log_in_user(build_conn(), user)
        assert {:error, {:redirect, %{to: "/users/settings"}}} = live(conn, ~p"/admin/vendors")
      end
    end

    test "an admin sees the review surface" do
      conn = log_in_user(build_conn(), admin_fixture())
      {:ok, view, _html} = live(conn, ~p"/admin/vendors")

      assert has_element?(view, "h1", "Vendor applications")
      assert has_element?(view, "#pending-applications")
    end

    test "the admin nav link is shown only to admins" do
      {:ok, admin_view, _} = live(log_in_user(build_conn(), admin_fixture()), ~p"/catalog")
      assert has_element?(admin_view, "#nav-admin-vendors")

      {:ok, user_view, _} = live(log_in_user(build_conn(), user_fixture()), ~p"/catalog")
      refute has_element?(user_view, "#nav-admin-vendors")
    end
  end

  describe "the pending list" do
    test "shows each pending application with the account's address" do
      user = user_fixture()
      profile = vendor_profile_fixture(user, %{display_name: "Ada's Shop"})

      {:ok, view, _html} = live(log_in_user(build_conn(), admin_fixture()), ~p"/admin/vendors")

      assert has_element?(view, "#application-#{profile.id}")
      assert has_element?(view, "#application-#{profile.id}", "Ada's Shop")
      assert render(view) =~ user.email
    end

    test "shows an empty state when nothing is pending" do
      {:ok, view, _html} = live(log_in_user(build_conn(), admin_fixture()), ~p"/admin/vendors")

      assert has_element?(view, "#no-pending-applications")
    end
  end

  describe "approving" do
    test "approves the profile and grants the vendor role" do
      user = user_fixture()
      profile = vendor_profile_fixture(user, %{display_name: "Ada's Shop"})

      {:ok, view, _html} = live(log_in_user(build_conn(), admin_fixture()), ~p"/admin/vendors")

      view
      |> element("#approve-application-#{profile.id}")
      |> render_submit()

      assert has_element?(view, "#flash-info", "Approved Ada's Shop.")
      assert Repo.get!(VendorProfile, profile.id).status == :approved
      assert Accounts.user_has_role?(user, :vendor)

      # It has moved out of the pending list and into the reviewed list.
      refute has_element?(view, "#application-#{profile.id}")
      assert has_element?(view, "#reviewed-#{profile.id}")
    end
  end

  describe "rejecting" do
    test "rejects the profile without granting a role" do
      user = user_fixture()
      profile = vendor_profile_fixture(user, %{display_name: "Ada's Shop"})

      {:ok, view, _html} = live(log_in_user(build_conn(), admin_fixture()), ~p"/admin/vendors")

      view
      |> element("#reject-application-#{profile.id}")
      |> render_submit()

      assert has_element?(view, "#flash-info", "Rejected Ada's Shop.")
      assert Repo.get!(VendorProfile, profile.id).status == :rejected
      refute Accounts.user_has_role?(user, :vendor)

      refute has_element?(view, "#application-#{profile.id}")
      assert has_element?(view, "#reviewed-#{profile.id}")
    end
  end

  describe "tampered events" do
    test "an unknown application id is a non-enumerable error" do
      {:ok, view, _html} = live(log_in_user(build_conn(), admin_fixture()), ~p"/admin/vendors")

      html = render_submit(view, "approve", %{"id" => "999999"})

      assert html =~ "no longer available"

      # A non-numeric id is just as inert.
      html = render_submit(view, "reject", %{"id" => "not-a-number"})
      assert html =~ "no longer available"
    end
  end

  describe "the context boundary" do
    test "a non-admin cannot approve even by reaching the context directly" do
      user = user_fixture()
      profile = vendor_profile_fixture(user)

      assert {:error, :not_authorized} =
               Vendors.approve_profile(Cass.Accounts.Scope.for_user(vendor_fixture()), profile)

      assert Repo.get!(VendorProfile, profile.id).status == :pending
    end
  end
end
