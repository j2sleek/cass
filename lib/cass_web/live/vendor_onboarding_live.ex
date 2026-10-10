defmodule CassWeb.VendorOnboardingLive do
  @moduledoc """
  Vendor onboarding (`/sell`).

  Any signed-in account can apply to sell: the form writes a
  `Cass.Vendors.VendorProfile` and nothing more. The page then shows where the
  application stands — `pending` while it waits for review, `approved` once an
  admin accepts it (which is also what grants the `:vendor` role), or
  `rejected`, in which case editing and saving resubmits it.

  The page never sets a status and never touches a role. `Cass.Vendors` derives
  the status from the caller's own roles, and approval lives on the admin review
  surface (`CassWeb.AdminVendorsLive`), so there is no self-service escalation
  here.
  """
  use CassWeb, :live_view

  alias Cass.Vendors

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sell on CASS · CASS Marketplace")
     |> assign(:meta_description, "Apply to sell on the CASS marketplace.")
     |> assign(:robots, "noindex, nofollow")
     |> assign(:profile, Vendors.get_profile(socket.assigns.current_scope))
     |> assign_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/sell"}>
      <div class="mx-auto w-full max-w-2xl space-y-8">
        <.header>
          Sell on CASS
          <:subtitle>
            Set up the seller profile buyers see. Applications are reviewed before they go live.
          </:subtitle>
        </.header>

        <.status_banner
          :if={@profile}
          profile={@profile}
          vendor?={Cass.Accounts.Scope.vendor?(@current_scope)}
        />

        <section
          id="vendor-profile-section"
          class="rounded-2xl border border-zinc-200 bg-white/80 p-6 shadow-sm backdrop-blur sm:p-8 dark:border-white/10 dark:bg-white/5"
        >
          <h2 class="text-base font-semibold text-zinc-900 dark:text-white">
            {if @profile, do: "Seller profile", else: "Your seller profile"}
          </h2>
          <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
            Your display name is shown on the products you sell. Everything else is optional.
          </p>

          <.form
            for={@form}
            id="vendor-profile-form"
            phx-change="validate"
            phx-submit="save"
            class="mt-5 space-y-4"
          >
            <.input
              field={@form[:display_name]}
              type="text"
              label="Display name"
              autocomplete="organization"
              required
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@form[:business_name]}
              type="text"
              label="Business name (optional)"
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@form[:bio]}
              type="textarea"
              label="About you (optional)"
              rows="4"
              class="form-input"
              error_class="form-input-error"
            />
            <.input
              field={@form[:website]}
              type="url"
              label="Website (optional)"
              placeholder="https://example.com"
              class="form-input"
              error_class="form-input-error"
            />

            <.button type="submit" phx-disable-with="Saving..." class="mt-2">
              {if @profile, do: "Save profile", else: "Submit application"}
            </.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :profile, :map, required: true
  attr :vendor?, :boolean, required: true

  defp status_banner(assigns) do
    ~H"""
    <div
      id="vendor-status"
      class={[
        "rounded-2xl border p-5 text-sm",
        status_banner_class(@profile.status)
      ]}
    >
      <p class="font-semibold">{status_banner_title(@profile.status)}</p>
      <p class="mt-1">{status_banner_body(@profile.status, @vendor?)}</p>
      <.link
        :if={@profile.status == :approved}
        navigate={~p"/manage/products"}
        class="mt-3 inline-flex items-center gap-1.5 font-semibold underline underline-offset-2"
      >
        Manage your products <.icon name="hero-arrow-right" class="size-4" />
      </.link>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"vendor_profile" => params}, socket) do
    form =
      socket.assigns.profile
      |> Vendors.change_profile(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "vendor_profile")

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"vendor_profile" => params}, socket) do
    case Vendors.save_profile(socket.assigns.current_scope, params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profile, profile)
         |> put_flash(:info, "Your seller profile has been saved.")
         |> assign_form()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(Map.put(changeset, :action, :insert), as: "vendor_profile")
         )}

      {:error, :not_authenticated} ->
        {:noreply,
         socket
         |> put_flash(:error, "You must log in to apply.")
         |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  defp assign_form(socket) do
    form =
      (socket.assigns.profile || %Vendors.VendorProfile{})
      |> Vendors.change_profile()
      |> to_form(as: "vendor_profile")

    assign(socket, :form, form)
  end

  defp status_banner_class(:pending),
    do:
      "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-500/30 dark:bg-amber-500/5 dark:text-amber-200"

  defp status_banner_class(:approved),
    do:
      "border-brand-200 bg-brand-50 text-brand-900 dark:border-brand-500/30 dark:bg-brand-500/5 dark:text-brand-200"

  defp status_banner_class(:rejected),
    do:
      "border-red-200 bg-red-50 text-red-900 dark:border-red-500/30 dark:bg-red-500/5 dark:text-red-200"

  defp status_banner_title(:pending), do: "Application under review"
  defp status_banner_title(:approved), do: "You are an approved seller"
  defp status_banner_title(:rejected), do: "Application not approved"

  defp status_banner_body(:pending, _vendor?),
    do: "We will let you know once your profile has been reviewed."

  defp status_banner_body(:approved, true),
    do: "Your display name is shown on the products you sell."

  defp status_banner_body(:approved, false),
    do:
      "Your profile is approved. An administrator still needs to enable selling for your account."

  defp status_banner_body(:rejected, _vendor?),
    do: "You can update your details below and submit it again for another review."
end
