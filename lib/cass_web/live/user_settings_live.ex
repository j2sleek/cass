defmodule CassWeb.UserSettingsLive do
  @moduledoc """
  Account settings for the signed-in user (`/users/settings`).

  Two independent forms:

    * **email** — a change is *requested* here and only applied once the new
      address is confirmed, so a typo in this form cannot lock anyone out. Both
      the current session and the link in the new mailbox are required.
    * **password** — applied immediately after the current password is
      verified. Every other session of the account is revoked; the session this
      form was submitted from stays signed in.
  """
  use CassWeb, :live_view

  alias Cass.Accounts

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:session_token, session["user_token"])
     |> assign_email_form()
     |> assign_password_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-2xl space-y-8">
        <.header>
          Account settings
          <:subtitle>Manage the email address and password of your account.</:subtitle>
        </.header>

        <section
          id="email-section"
          class="rounded-2xl border border-zinc-200 bg-white/80 p-6 shadow-sm backdrop-blur sm:p-8 dark:border-white/10 dark:bg-white/5"
        >
          <h2 class="text-base font-semibold text-zinc-900 dark:text-white">Email address</h2>
          <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            Your current address is <span class="font-medium">{@user.email}</span>.
            We will send a confirmation link to the new address before anything changes.
          </p>

          <.form
            for={@email_form}
            id="email-form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="New email"
              autocomplete="email"
              spellcheck="false"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@email_form[:current_password]}
              type="password"
              id="email-current-password"
              name="current_password"
              label="Current password"
              autocomplete="current-password"
              spellcheck="false"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              Required to confirm that this is really your account.
            </p>

            <.button type="submit" phx-disable-with="Sending..." class="mt-4">Change email</.button>
          </.form>
        </section>

        <section
          id="password-section"
          class="rounded-2xl border border-zinc-200 bg-white/80 p-6 shadow-sm backdrop-blur sm:p-8 dark:border-white/10 dark:bg-white/5"
        >
          <h2 class="text-base font-semibold text-zinc-900 dark:text-white">Password</h2>
          <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            Changing your password signs you out everywhere else.
          </p>

          <.form
            for={@password_form}
            id="password-form"
            phx-submit="update_password"
            phx-change="validate_password"
          >
            <.input
              field={@password_form[:current_password]}
              type="password"
              id="current-password"
              name="current_password"
              label="Current password"
              autocomplete="current-password"
              spellcheck="false"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              class="form-input"
              error_class="form-input-error"
            />
            <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">
              Use at least {Cass.Accounts.User.password_min_length()} characters.
            </p>

            <.button type="submit" phx-disable-with="Updating..." class="mt-4">Change password</.button>
          </.form>
        </section>

        <section
          id="danger-zone"
          class="rounded-2xl border border-red-200 bg-red-50/60 p-6 sm:p-8 dark:border-red-500/30 dark:bg-red-500/5"
        >
          <h2 class="text-base font-semibold text-red-900 dark:text-red-200">Sign out</h2>
          <p class="mt-1 text-sm text-red-800/80 dark:text-red-300/80">
            Ends this session on this device.
          </p>

          <.form
            for={to_form(%{}, as: "user")}
            id="log-out-form"
            action={~p"/users/log-out"}
            method="delete"
          >
            <.button type="submit" variant="secondary" class="mt-4">Log out</.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  ## Forms
  #
  # Live validation deliberately skips the current password check
  # (`:validate_current_password` is off while the form is being filled in): it is
  # verified on submit, where a wrong value is reported as a normal field error.

  @impl true
  def handle_event("validate_email", %{"user" => user_params}, socket) do
    email_form =
      socket.assigns.user
      |> Accounts.change_user_email(user_params, validate_current_password: false)
      |> Map.put(:action, :validate)
      |> to_form(as: "user")

    {:noreply, assign(socket, :email_form, email_form)}
  end

  def handle_event(
        "update_email",
        %{"current_password" => password, "user" => user_params},
        socket
      ) do
    user = socket.assigns.user

    case Accounts.change_user_email(user, Map.put(user_params, "current_password", password)) do
      %{valid?: true} = changeset ->
        # The address is only changed once the new mailbox confirms it, so this
        # sends the link and keeps the old address in place.
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "A link to confirm your email change has been sent to the new address."
         )
         |> assign_email_form()}

      changeset ->
        {:noreply,
         assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert), as: "user"))}
    end
  end

  @impl true
  def handle_event("validate_password", %{"user" => user_params}, socket) do
    password_form =
      socket.assigns.user
      |> Accounts.change_user_password(user_params, validate_current_password: false)
      |> Map.put(:action, :validate)
      |> to_form(as: "user")

    {:noreply, assign(socket, :password_form, password_form)}
  end

  def handle_event(
        "update_password",
        %{"current_password" => password, "user" => user_params},
        socket
      ) do
    user = socket.assigns.user

    case Accounts.update_user_password(
           user,
           password,
           user_params,
           keep_session_token: socket.assigns.session_token
         ) do
      {:ok, {user, expired_tokens}} ->
        CassWeb.UserAuth.disconnect_sessions(expired_tokens)

        {:noreply,
         socket
         |> assign(:user, user)
         |> put_flash(:info, "Password updated. You have been signed out on other devices.")
         |> assign_password_form()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :password_form, to_form(Map.put(changeset, :action, :insert), as: "user"))}
    end
  end

  defp assign_email_form(socket) do
    assign(
      socket,
      :email_form,
      to_form(Accounts.change_user_email(socket.assigns.user), as: "user")
    )
  end

  defp assign_password_form(socket) do
    assign(
      socket,
      :password_form,
      to_form(Accounts.change_user_password(socket.assigns.user), as: "user")
    )
  end
end
