defmodule CassWeb.UserRegistrationLive do
  @moduledoc """
  Registration page (`/users/register`).

  Registration requires an email address **and** a password: the password is
  validated, hashed with PBKDF2, and the plaintext value never leaves the
  changeset (it is redacted, and removed from the change set once hashed).
  """
  use CassWeb, :live_view

  alias Cass.Accounts
  alias Cass.Accounts.User
  alias CassWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:ok, redirect(socket, to: UserAuth.signed_in_path(socket))}
    else
      {:ok, assign_form(socket, Accounts.change_user_registration(%User{}))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/users/register"}>
      <.auth_card id="registration-card">
        <:title>Create your account</:title>
        <:subtitle>
          Already have an account?
          <.link navigate={~p"/users/log-in"} class="font-semibold text-brand-600 hover:underline">
            Sign in
          </.link>
          instead.
        </:subtitle>

        <.form for={@form} id="registration-form" phx-submit="save" phx-change="validate">
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
            autocomplete="new-password"
            required
            class="form-input"
            error_class="form-input-error"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            class="form-input"
            error_class="form-input-error"
          />

          <p class="mt-1 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
            Use at least {Cass.Accounts.User.password_min_length()} characters. A passphrase of a few words works well.
          </p>

          <.button type="submit" phx-disable-with="Creating account..." class="mt-5 w-full">
            Create account
          </.button>
        </.form>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params, validate_unique: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Account created. We sent a confirmation link to #{user.email} — open it, then sign in."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
