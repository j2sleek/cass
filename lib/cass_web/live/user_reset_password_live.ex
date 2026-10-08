defmodule CassWeb.UserResetPasswordLive do
  @moduledoc """
  Choose a new password (`/users/reset-password/:token`).

  The token is consumed on success and every other session of that account is
  revoked, so the user signs in again with the new password.
  """
  use CassWeb, :live_view

  alias Cass.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok, socket |> assign(:token, token) |> assign_user_and_token() |> assign_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/users/log-in"}>
      <.auth_card id="reset-password-card">
        <:title>Choose a new password</:title>
        <:subtitle>
          After saving, you will be signed out everywhere and will use the new
          password from now on.
        </:subtitle>

        <%= if @form do %>
          <.form for={@form} id="reset-password-form" phx-submit="reset_password">
            <.input
              field={@form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              Use at least {Cass.Accounts.User.password_min_length()} characters.
            </p>
            <.button type="submit" phx-disable-with="Saving..." class="mt-5 w-full">
              Save new password
            </.button>
          </.form>
        <% else %>
          <p class="text-sm text-zinc-600 dark:text-zinc-400">
            This password reset link is invalid or it has expired. Reset links
            are single use and expire after 1 hour.
          </p>
          <.link
            navigate={~p"/users/reset-password"}
            class="mt-4 block text-sm font-medium text-brand-600 hover:underline"
          >
            Request a new reset link
          </.link>
        <% end %>

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
  def handle_event("reset_password", %{"user" => user_params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, socket.assigns.token, user_params) do
      {:ok, {_user, _expired_tokens}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password reset successfully. You can sign in now.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(Map.put(changeset, :action, :insert), as: "user"))}

      {:error, :invalid_token} ->
        {:noreply, socket |> assign_user_and_token() |> assign_form()}
    end
  end

  # A valid reset token always resolves to the account it was issued for, so the
  # user never comes from the request.
  defp assign_user_and_token(socket) do
    case Accounts.get_user_by_valid_reset_password_token(socket.assigns.token) do
      {user, %Accounts.UserToken{}} -> assign(socket, :user, user)
      nil -> assign(socket, :user, nil)
    end
  end

  defp assign_form(socket) do
    form =
      if socket.assigns.user do
        to_form(Accounts.change_user_password(socket.assigns.user), as: "user")
      end

    assign(socket, :form, form)
  end
end
