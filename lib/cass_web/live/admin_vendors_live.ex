defmodule CassWeb.AdminVendorsLive do
  @moduledoc """
  The admin vendor review dashboard (`/admin/vendors`).

  Applicants submit a `Cass.Vendors.VendorProfile` with `status: :pending` from
  `/sell`; this is where an admin approves or rejects it. **Approval is the only
  thing that grants the `:vendor` role** (inside
  `Cass.Vendors.approve_profile/2`, in the same transaction as the status
  change), which is what keeps "no route grants a role" true: the admin names an
  application, never a role, and the role applied is fixed by the context.

  Two layers guard the page, as with the rest of the management surfaces: the
  route sits behind the `:require_admin` plug and LiveView hook, and every
  action re-resolves the profile through
  `Cass.Vendors.get_reviewable_profile/2`, which returns `nil` for a non-admin
  scope, so a tampered id is inert.
  """
  use CassWeb, :live_view

  alias Cass.Vendors

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Vendor applications · CASS Marketplace")
     |> assign(:meta_description, "Review vendor applications.")
     |> assign(:robots, "noindex, nofollow")
     |> assign_profiles()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={~p"/admin/vendors"}
    >
      <section class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          Vendor applications
        </h1>
        <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
          Approving an applicant grants them the vendor role and publishes their display name on
          the products they sell.
        </p>
      </section>

      <section id="pending-applications" class="pt-8">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Pending ({length(@pending)})
        </h2>

        <p
          :if={@pending == []}
          id="no-pending-applications"
          class="mt-4 rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-500 dark:border-white/10 dark:text-zinc-400"
        >
          No applications are waiting for review.
        </p>

        <ul class="mt-5 space-y-3">
          <li
            :for={profile <- @pending}
            id={"application-#{profile.id}"}
            class="flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm sm:flex-row sm:items-start sm:justify-between dark:border-white/10 dark:bg-white/5"
          >
            <div class="min-w-0">
              <p class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                {profile.display_name}
              </p>
              <p class="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
                {profile.user.email}
                <span :if={profile.business_name}> · {profile.business_name}</span>
              </p>
              <p
                :if={profile.bio}
                class="mt-2 max-w-prose text-sm text-zinc-600 dark:text-zinc-300"
              >
                {profile.bio}
              </p>
              <.website_link :if={profile.website} href={profile.website} />
            </div>

            <div class="flex shrink-0 flex-wrap items-center gap-2">
              <.form
                for={to_form(%{}, as: "approve")}
                id={"approve-application-#{profile.id}"}
                phx-submit="approve"
                phx-value-id={profile.id}
              >
                <button
                  id={"approve-button-#{profile.id}"}
                  type="submit"
                  phx-disable-with="Approving..."
                  class="rounded-lg bg-brand-600 px-3 py-1.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700"
                >
                  Approve
                </button>
              </.form>
              <.form
                for={to_form(%{}, as: "reject")}
                id={"reject-application-#{profile.id}"}
                phx-submit="reject"
                phx-value-id={profile.id}
              >
                <button
                  id={"reject-button-#{profile.id}"}
                  type="submit"
                  phx-disable-with="Rejecting..."
                  class="rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition hover:border-red-300 hover:text-red-600 dark:border-white/10 dark:text-zinc-200"
                >
                  Reject
                </button>
              </.form>
            </div>
          </li>
        </ul>
      </section>

      <section :if={@reviewed != []} id="reviewed-applications" class="pt-10">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Reviewed
        </h2>

        <ul class="mt-5 space-y-3">
          <li
            :for={profile <- @reviewed}
            id={"reviewed-#{profile.id}"}
            class="flex items-center justify-between gap-4 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-white/5"
          >
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                {profile.display_name}
              </p>
              <p class="mt-0.5 truncate text-xs text-zinc-500 dark:text-zinc-400">
                {profile.user.email}
              </p>
            </div>
            <span class={[
              "rounded-full px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide uppercase",
              status_class(profile.status)
            ]}>
              {profile.status}
            </span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :href, :string, required: true

  defp website_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="mt-2 inline-flex items-center gap-1 text-xs font-medium text-brand-700 underline underline-offset-2 dark:text-brand-300"
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> {@href}
    </a>
    """
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    review(socket, id, "Approved", fn profile ->
      Vendors.approve_profile(socket.assigns.current_scope, profile)
    end)
  end

  def handle_event("reject", %{"id" => id}, socket) do
    review(socket, id, "Rejected", fn profile ->
      Vendors.reject_profile(socket.assigns.current_scope, profile)
    end)
  end

  defp review(socket, id, action, fun) do
    case Vendors.get_reviewable_profile(socket.assigns.current_scope, id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That application is no longer available.")
         |> assign_profiles()}

      profile ->
        case fun.(profile) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{action} #{updated.display_name}.")
             |> assign_profiles()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "The application could not be updated.")
             |> assign_profiles()}
        end
    end
  end

  defp assign_profiles(socket) do
    {pending, reviewed} =
      socket.assigns.current_scope
      |> Vendors.list_profiles()
      |> Enum.split_with(&(&1.status == :pending))

    socket
    |> assign(:pending, pending)
    |> assign(:reviewed, reviewed)
  end

  defp status_class(:approved),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"

  defp status_class(:rejected),
    do: "bg-red-50 text-red-700 dark:bg-red-500/10 dark:text-red-300"

  defp status_class(_status),
    do: "bg-zinc-100 text-zinc-600 dark:bg-white/10 dark:text-zinc-300"
end
