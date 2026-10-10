defmodule CassWeb.VendorOnboardingLiveTest do
  @moduledoc """
  Tests for the vendor onboarding surface (`/sell`): applying, resubmitting,
  and what the page shows once an application has been reviewed.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cass.AccountsFixtures

  alias Cass.Accounts
  alias Cass.Accounts.Scope
  alias Cass.Vendors

  describe "access" do
    test "a guest is sent to the login page" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/sell")
    end

    test "a signed-in account reaches the form", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/sell")

      assert has_element?(view, "#vendor-profile-form")
      assert has_element?(view, "#vendor-profile-form input[name='vendor_profile[display_name]']")
      # No profile yet, so no status banner.
      refute has_element?(view, "#vendor-status")
    end
  end

  describe "applying" do
    test "a customer's application is stored as pending", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/sell")

      html =
        view
        |> form("#vendor-profile-form", vendor_profile: %{display_name: "Ada's Shop"})
        |> render_submit()

      assert html =~ "Your seller profile has been saved."
      assert has_element?(view, "#vendor-status")

      profile = Vendors.get_profile_for_user(user)
      assert profile.status == :pending
      assert profile.display_name == "Ada's Shop"

      # Applying grants nothing.
      refute Accounts.user_has_role?(user, :vendor)
    end

    test "a blank submission is refused with a field error", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/sell")

      view
      |> form("#vendor-profile-form", vendor_profile: %{display_name: ""})
      |> render_submit()

      assert has_element?(view, "#vendor-profile-form", "can't be blank")
      assert Vendors.get_profile_for_user(user) == nil
    end
  end

  describe "once reviewed" do
    test "an approved seller sees the approved state and edits stay approved", %{conn: conn} do
      user = user_fixture()
      approved_vendor_profile_fixture(user, %{display_name: "Ada's Shop"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/sell")

      assert has_element?(view, "#vendor-status", "You are an approved seller")

      html =
        view
        |> form("#vendor-profile-form", vendor_profile: %{display_name: "Ada's Boutique"})
        |> render_submit()

      assert html =~ "Your seller profile has been saved."
      profile = Vendors.get_profile_for_user(user)
      assert profile.display_name == "Ada's Boutique"
      assert profile.status == :approved
    end

    test "a rejected applicant can edit and resubmit", %{conn: conn} do
      user = user_fixture()
      profile = vendor_profile_fixture(user, %{display_name: "Ada's Shop"})

      {:ok, _} = Vendors.reject_profile(Scope.for_user(admin_fixture()), profile)

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/sell")
      assert has_element?(view, "#vendor-status", "Application not approved")

      html =
        view
        |> form("#vendor-profile-form", vendor_profile: %{display_name: "Ada's Shop, updated"})
        |> render_submit()

      assert html =~ "Your seller profile has been saved."
      assert Vendors.get_profile_for_user(user).status == :pending
    end
  end

  describe "navigation" do
    test "the Sell link is shown to any signed-in account", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/catalog")

      assert has_element?(view, "#nav-sell")
    end
  end
end
