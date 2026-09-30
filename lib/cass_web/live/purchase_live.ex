defmodule CassWeb.PurchaseLive do
  @moduledoc """
  The access page for one purchase: `GET /purchases/:id`.

  This is the surface where Milestone 8's distinction becomes visible to a
  buyer. An **entitlement** proves the purchase succeeded and the buyer holds the
  right; this page shows **delivery** — how that right is actually exercised.

  It deliberately does no authorization work of its own. The page resolves
  exactly one thing, `Cass.Delivery.authorize_access(current_scope, id)`, and
  that one call decides authentication, ownership, entitlement state, and
  whether the purchase's delivery mechanism is exercisable at all. The page
  renders the granted capability or the shared not-found state; it never
  re-derives "is this mine?", never reads `user_id` from the URL, and never
  reimplements the active/revoked/expired rule.

  Because every refusal — unknown id, somebody else's purchase, a revoked
  grant, an elapsed one, and a mechanism this milestone cannot issue yet — comes
  back as the same refusal, they all render as the same page. A buyer cannot use
  this URL to discover whether an id exists, whose it was, or why it failed.

  The page is `noindex`: it is a private capability, never a public listing, and
  it is reachable from the buyer's own order page rather than from a dashboard.
  """
  use CassWeb, :live_view

  alias Cass.Delivery
  alias CassWeb.NotFound

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Your access · CASS Marketplace")
    |> assign(:meta_description, "Access details for a purchase.")
    |> assign(:robots, "noindex, nofollow")
    |> assign(:access, nil)
    |> assign(:purchase_not_found, true)
    |> ok()
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, resolve(socket, id)}
  end

  defp resolve(socket, id) do
    # One call, one decision. Ownership, entitlement state, and mechanism all
    # live behind it, so this page cannot grant what the context refuses.
    socket = assign(socket, access: nil, purchase_not_found: true)

    case Delivery.authorize_access(socket.assigns.current_scope, id) do
      {:ok, access} ->
        socket
        |> assign(:access, access)
        |> assign(:purchase_not_found, false)
        |> assign(:page_title, "#{access.product_name} · Your access · CASS Marketplace")

      {:error, _refusal} ->
        socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @purchase_not_found do %>
        <NotFound.not_found resource="purchase" />
      <% else %>
        <.access_details access={@access} />
      <% end %>
    </Layouts.app>
    """
  end

  attr :access, :any, required: true

  defp access_details(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-3xl">
      <div class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <p class="text-xs font-semibold tracking-widest text-brand-700 uppercase dark:text-brand-300">
          Delivered
        </p>
        <h1 class="mt-2 text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          {@access.product_name}
        </h1>
        <p class="mt-3 text-base leading-7 text-zinc-600 dark:text-zinc-300">
          You bought this, it was delivered, and this is how you use it.
        </p>
      </div>

      <div
        id="access-code-panel"
        class="mt-8 rounded-2xl border border-brand-200 bg-brand-50/60 p-6 shadow-sm dark:border-brand-500/30 dark:bg-brand-500/10"
      >
        <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
          Your access code
        </h2>
        <p class="mt-2 text-sm leading-6 text-zinc-600 dark:text-zinc-300">
          Keep this code. It is how this purchase is recognised, and it is the
          same every time you come back here.
        </p>
        <p
          id="access-code"
          class="mt-4 select-all font-mono text-2xl font-semibold tracking-[0.2em] text-zinc-900 sm:text-3xl dark:text-white"
        >
          {@access.access_code}
        </p>
      </div>

      <dl id="access-details" class="mt-8 grid gap-6 sm:grid-cols-2">
        <.detail label="Product">
          {@access.product_name}
        </.detail>
        <.detail label="Configuration">{@access.variant_name}</.detail>
        <.detail label="Quantity">{@access.quantity}</.detail>
        <.detail label="Delivered via">{mechanism_label(@access.mechanism)}</.detail>
        <.detail label="Granted">{Calendar.strftime(@access.granted_at, "%b %-d, %Y")}</.detail>
        <.detail label="Access ends">
          <%= if @access.expires_at do %>
            {Calendar.strftime(@access.expires_at, "%b %-d, %Y")}
          <% else %>
            <span class="text-zinc-500 dark:text-zinc-400">Does not expire</span>
          <% end %>
        </.detail>
        <%= if @access.sku do %>
          <.detail label="SKU">{@access.sku}</.detail>
        <% end %>
      </dl>

      <p class="mt-10 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
        Lost this code? It is tied to the purchase, so it has not changed — and if you
        no longer have access, it stops working immediately.
      </p>
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div>
      <dt class="text-xs font-semibold tracking-wide text-zinc-500 uppercase dark:text-zinc-400">
        {@label}
      </dt>
      <dd class="mt-1 text-sm text-zinc-900 dark:text-white">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp mechanism_label(:access_code), do: "Access code"
  defp mechanism_label(mechanism), do: mechanism |> to_string() |> String.replace("_", " ")

  defp ok(socket), do: {:ok, socket}
end
