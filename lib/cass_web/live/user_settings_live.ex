defmodule CassWeb.UserSettingsLive do
  @moduledoc """
  Account settings for the signed-in user (`/users/settings`).

  Four independent concerns:

    * **email** — a change is *requested* here and only applied once the new
      address is confirmed, so a typo in this form cannot lock anyone out. Both
      the current session and the link in the new mailbox are required.
    * **password** — applied immediately after the current password is
      verified. Every other session of the account is revoked; the session this
      form was submitted from stays signed in.
    * **sessions** — the devices the account is currently signed in on, with a
      per-session revoke and a "sign out everywhere". Sessions are identified by
      their token row id, never by the token value.
    * **account deletion** — a deactivation, performed after the account types
      its own address to confirm. An account that still owns products is refused
      (see `Cass.Accounts.delete_user/1`); the page reports that and changes
      nothing.
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
     |> assign_password_form()
     |> assign_delete_account_form()
     |> assign_sessions()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/users/settings"}>
      <div class="mx-auto w-full max-w-2xl space-y-8">
        <.header>
          Account settings
          <:subtitle>
            Manage your email address, password, active sessions, and account lifecycle.
          </:subtitle>
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
          id="sessions-section"
          class="rounded-2xl border border-zinc-200 bg-white/80 p-6 shadow-sm backdrop-blur sm:p-8 dark:border-white/10 dark:bg-white/5"
        >
          <h2 class="text-base font-semibold text-zinc-900 dark:text-white">
            Where you're signed in
          </h2>
          <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            Sessions are listed by when they signed in. Revoke one you do not recognize.
          </p>

          <ul id="sessions" class="mt-4 divide-y divide-zinc-100 dark:divide-white/10">
            <li
              :for={session <- @sessions}
              id={"session-#{session.id}"}
              class="flex items-center justify-between gap-4 py-3"
            >
              <div class="min-w-0">
                <p class="text-sm font-medium text-zinc-800 dark:text-zinc-100">
                  {if session.current?, do: "This device", else: "Session"}
                </p>
                <p class="text-xs text-zinc-500 dark:text-zinc-400">
                  Signed in {format_session_time(session.inserted_at)}
                </p>
              </div>

              <button
                :if={!session.current?}
                id={"revoke-session-#{session.id}"}
                type="button"
                phx-click="revoke_session"
                phx-value-id={session.id}
                phx-disable-with="Revoking..."
                class="shrink-0 rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition hover:border-red-300 hover:text-red-600 dark:border-white/10 dark:text-zinc-200"
              >
                Revoke
              </button>
              <span
                :if={session.current?}
                class="shrink-0 rounded-full bg-brand-50 px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide text-brand-700 uppercase dark:bg-brand-500/10 dark:text-brand-300"
              >
                Active
              </span>
            </li>
          </ul>

          <button
            id="sign-out-everywhere"
            type="button"
            phx-click="sign_out_everywhere"
            phx-disable-with="Signing out..."
            class="mt-4 rounded-lg border border-zinc-200 px-3 py-2 text-sm font-medium text-zinc-700 transition hover:border-red-300 hover:text-red-600 dark:border-white/10 dark:text-zinc-200"
          >
            Sign out everywhere
          </button>
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

          <div class="mt-8 border-t border-red-200/70 pt-6 dark:border-red-500/20">
            <h3 class="text-base font-semibold text-red-900 dark:text-red-200">Delete account</h3>
            <p class="mt-1 text-sm text-red-800/80 dark:text-red-300/80">
              Deactivates your account, signs you out everywhere, and erases your sign-in
              details. Your order history and receipts are kept. If you still own products,
              archive or transfer them first — an account with a catalog cannot be deleted.
            </p>

            <.form
              for={@delete_account_form}
              id="delete-account-form"
              phx-submit="delete_account"
              class="mt-4"
            >
              <.input
                field={@delete_account_form[:confirmation]}
                type="text"
                id="delete-account-confirmation"
                label={"Type #{@user.email} to confirm"}
                autocomplete="off"
                spellcheck="false"
                required
                class="form-input"
                error_class="form-input-error"
              />
              <button
                id="delete-account-button"
                type="submit"
                phx-disable-with="Deleting..."
                class="mt-3 rounded-lg bg-red-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-red-700 focus-visible:ring-2 focus-visible:ring-red-500 focus-visible:ring-offset-2 focus-visible:outline-none"
              >
                Delete my account
              </button>
            </.form>
          </div>
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

  def handle_event("revoke_session", %{"id" => id}, socket) do
    Accounts.revoke_user_session(socket.assigns.user, id)

    {:noreply,
     socket
     |> put_flash(:info, "That session has been signed out.")
     |> assign_sessions()}
  end

  def handle_event("sign_out_everywhere", _params, socket) do
    Accounts.delete_user_sessions(socket.assigns.user)

    # The token in this browser's cookie is revoked along with the rest, so the
    # next request resolves as a guest and the login page is the honest
    # destination.
    {:noreply,
     socket
     |> put_flash(:info, "You have been signed out on every device.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("delete_account", %{"user" => %{"confirmation" => confirmation}}, socket) do
    if String.trim(confirmation) == socket.assigns.user.email do
      delete_account(socket)
    else
      {:noreply,
       socket
       |> put_flash(:error, "The address you typed does not match your account.")
       |> assign_delete_account_form()}
    end
  end

  defp delete_account(socket) do
    case Accounts.delete_user(socket.assigns.user) do
      {:ok, {_user, revoked_tokens}} ->
        CassWeb.UserAuth.disconnect_sessions(other_sessions(revoked_tokens, socket))

        {:noreply,
         socket
         |> put_flash(:info, "Your account has been deleted.")
         |> push_navigate(to: ~p"/")}

      {:error, :owns_products} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Your account still owns products. Archive or transfer them before deleting your account."
         )
         |> assign_delete_account_form()}
    end
  end

  # The current session is revoked too, but its socket is not disconnected from
  # under the redirect; the full navigation that follows clears it.
  defp other_sessions(tokens, socket) do
    Enum.reject(tokens, &(&1.token == socket.assigns.session_token))
  end

  defp assign_sessions(socket) do
    current_token = socket.assigns.session_token

    sessions =
      socket.assigns.user
      |> Accounts.list_user_sessions()
      |> Enum.map(fn token ->
        %{id: token.id, inserted_at: token.inserted_at, current?: token.token == current_token}
      end)

    assign(socket, :sessions, sessions)
  end

  defp assign_delete_account_form(socket) do
    assign(socket, :delete_account_form, to_form(%{"confirmation" => ""}, as: "user"))
  end

  defp format_session_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %Y at %H:%M UTC")

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
