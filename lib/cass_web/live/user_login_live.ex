defmodule CassWeb.UserLoginLive do
  @moduledoc """
  Login page (`/users/log-in`).

  The form posts to `CassWeb.UserSessionController.create/2`, which resolves
  the user server-side from the submitted email and password. Failures are
  answered with a single generic message, so neither this page nor the
  controller ever discloses whether an address is registered.
  """
  use CassWeb, :live_view

  alias CassWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:ok, redirect(socket, to: UserAuth.signed_in_path(socket))}
    else
      email = Phoenix.Flash.get(socket.assigns.flash, :email)

      {:ok,
       socket
       |> assign(:form, to_form(%{"email" => email}, as: "user"))
       |> assign(:trigger_submit, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/users/log-in"}>
      <.auth_card id="login-card">
        <:title>Sign in</:title>
        <:subtitle>
          New to CASS? <.link
            navigate={~p"/users/register"}
            class="font-semibold text-brand-600 hover:underline"
          >
            Create an account
          </.link>.
        </:subtitle>

        <.form
          for={@form}
          id="login-form"
          action={~p"/users/log-in"}
          method="post"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
            class="form-input"
            error_class="form-input-error"
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
            required
            class="form-input"
            error_class="form-input-error"
          />

          <.button type="submit" phx-disable-with="Signing in..." class="mt-5 w-full">
            Sign in
          </.button>
          <.button
            type="submit"
            name={@form[:remember_me].name}
            value="true"
            variant="secondary"
            class="mt-2 w-full"
            phx-disable-with="Signing in..."
          >
            Sign in and stay signed in for 14 days
          </.button>
        </.form>

        <p class="mt-5 text-center text-sm text-zinc-600 dark:text-zinc-400">
          <.link
            navigate={~p"/users/reset-password"}
            id="forgot-password-link"
            class="font-medium text-zinc-700 hover:text-brand-700 hover:underline dark:text-zinc-300 dark:hover:text-brand-300"
          >
            Forgot your password?
          </.link>
        </p>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
