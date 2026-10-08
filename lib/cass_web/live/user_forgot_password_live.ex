defmodule CassWeb.UserForgotPasswordLive do
  @moduledoc """
  Password reset request page (`/users/reset-password`).

  The response is identical whether or not the address is registered, so the
  page cannot be used to discover accounts. Delivery itself is deferred: with
  no email provider configured, the message is only rendered in the flash
  (see `docs/security.md`).
  """
  use CassWeb, :live_view

  alias Cass.Accounts

  @neutral_message "If your email is in our system, you will receive instructions to reset your password shortly."

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :form, to_form(%{}, as: "user"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/users/log-in"}>
      <.auth_card id="forgot-password-card">
        <:title>Reset your password</:title>
        <:subtitle>
          Enter your email address and we will send you a link to choose a new
          password. The link is valid for 1 hour.
        </:subtitle>

        <.form for={@form} id="reset-password-request-form" phx-submit="send_instructions">
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
          <.button type="submit" phx-disable-with="Sending..." class="mt-5 w-full">
            Send reset instructions
          </.button>
        </.form>

        <p class="mt-5 text-center text-sm text-zinc-600 dark:text-zinc-400">
          <.link navigate={~p"/users/log-in"} class="font-medium hover:text-brand-700 hover:underline">
            Back to sign in
          </.link>
        </p>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_user_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    {:noreply,
     socket
     |> put_flash(:info, @neutral_message)
     |> assign(:form, to_form(%{}, as: "user"))}
  end
end
