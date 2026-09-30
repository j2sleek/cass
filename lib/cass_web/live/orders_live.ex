defmodule CassWeb.OrdersLive do
  @moduledoc """
  The signed-in orders page: `/orders` (index) and `/orders/:id` (show).

  This is the smallest real surface that exercises checkout end to end. Every
  action resolves data through `Cass.Orders` with the caller's `current_scope`,
  which already enforces the ownership rule — an account sees only its own
  orders, an admin sees every order — so the page itself never decides
  ownership. A foreign, malformed, or unknown order id resolves to the same
  shared not-found state as a URL nobody can access.
  """
  use CassWeb, :live_view

  alias CassWeb.NotFound

  @impl true
  def mount(_params, _session, socket) do
    socket
    # Configured once; the dom id is what tests and CSS anchor on.
    |> stream_configure(:orders, dom_id: &"order-#{&1.id}")
    |> assign(:page_title, "Orders · CASS Marketplace")
    |> assign(:meta_description, "Your orders.")
    |> assign(:robots, "noindex, nofollow")
    |> assign(:order, nil)
    |> assign(:order_not_found, false)
    |> assign(:can_pay?, false)
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @live_action == :show do %>
        <.order_show
          order={@order}
          order_not_found={@order_not_found}
          can_pay?={@can_pay?}
          admin?={Cass.Accounts.Scope.admin?(@current_scope)}
        />
      <% else %>
        <.order_index orders={@streams.orders} />
      <% end %>
    </Layouts.app>
    """
  end

  attr :orders, :any, required: true

  defp order_index(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-4xl">
      <div class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          Orders
        </h1>
        <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
          Checkout places an order and reserves stock in one atomic step; the lines below
          are a snapshot of what was actually purchased.
        </p>
      </div>

      <div id="orders" phx-update="stream" class="mt-6 space-y-3">
        <div
          :for={{dom_id, order} <- @orders}
          id={dom_id}
          class="flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:border-brand-300 hover:shadow-md sm:flex-row sm:items-center sm:justify-between dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <.link
                navigate={~p"/orders/#{order.id}"}
                class="inline-flex items-center gap-2 font-semibold tracking-tight text-zinc-900 hover:text-brand-700 dark:text-white dark:hover:text-brand-300"
              >
                {order.number}
              </.link>
              <span class={[
                "rounded-full px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide uppercase",
                status_class(order.status)
              ]}>
                {order.status}
              </span>
            </div>
            <p class="mt-0.5 truncate text-xs text-zinc-500 dark:text-zinc-400">
              {format_date(order.inserted_at)} · {length(order.order_items)} item(s)
            </p>
          </div>

          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <span
              id={"order-total-#{order.id}"}
              class="text-sm font-semibold text-zinc-900 dark:text-white"
            >
              {money(order.total_cents, order.currency)}
            </span>
            <.link
              navigate={~p"/orders/#{order.id}"}
              class="rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:text-zinc-200 dark:hover:border-brand-400"
            >
              View
            </.link>
          </div>
        </div>

        <div
          id="orders-empty"
          class="hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-400 only:block dark:border-white/10"
        >
          No orders yet. Browse the catalog to make your first purchase.
        </div>
      </div>
    </section>
    """
  end

  attr :order, :any, required: true
  attr :order_not_found, :boolean, required: true
  attr :can_pay?, :boolean, required: true
  attr :admin?, :boolean, required: true

  defp order_show(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-4xl">
      <%= if @order_not_found do %>
        <NotFound.not_found resource="order" />
      <% else %>
        <nav
          aria-label="Breadcrumb"
          class="flex items-center gap-1.5 text-xs font-medium text-zinc-400 dark:text-zinc-500"
        >
          <.link
            navigate={~p"/orders"}
            class="transition hover:text-brand-700 dark:hover:text-brand-300"
          >
            Orders
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <span class="text-zinc-600 dark:text-zinc-300">{@order.number}</span>
        </nav>

        <div class="mt-6 flex flex-wrap items-center justify-between gap-4 border-b border-zinc-200/70 pb-8 dark:border-white/10">
          <div>
            <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
              {@order.number}
            </h1>
            <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
              Placed {format_date(@order.inserted_at)} · {String.upcase(@order.currency)}
            </p>
          </div>
          <span class={[
            "rounded-full px-3 py-1 text-xs font-semibold tracking-wide uppercase",
            status_class(@order.status)
          ]}>
            {@order.status}
          </span>
        </div>

        <div class="mt-6 grid gap-6 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
              Items
            </h2>
            <ul id="order-items" class="mt-4 space-y-3">
              <li
                :for={item <- @order.order_items}
                class="flex flex-col gap-3 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between dark:border-white/10 dark:bg-white/5"
              >
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                    {item.product_name}
                  </p>
                  <p class="mt-0.5 truncate text-xs text-zinc-500 dark:text-zinc-400">
                    {item.variant_name}{if item.sku, do: " · #{item.sku}"}
                  </p>
                </div>
                <div class="flex shrink-0 items-center gap-4 text-sm">
                  <span class="text-zinc-500 dark:text-zinc-400">
                    {item.quantity} × {money(item.unit_price_cents, item.currency)}
                  </span>
                  <span
                    id={"item-line-total-#{item.id}"}
                    class="font-semibold text-zinc-900 dark:text-white"
                  >
                    {money(Cass.Orders.OrderItem.line_total_cents(item), item.currency)}
                  </span>
                </div>
              </li>
            </ul>
          </div>

          <aside class="lg:col-span-1">
            <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-white/5">
              <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                Summary
              </h2>
              <dl class="mt-4 space-y-3 text-sm">
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Subtotal</dt>
                  <dd id="order-subtotal" class="font-medium text-zinc-900 dark:text-white">
                    {money(Cass.Orders.order_total_cents(@order), @order.currency)}
                  </dd>
                </div>
                <div class="flex items-center justify-between gap-4 border-t border-zinc-200 pt-3 dark:border-white/10">
                  <dt class="font-semibold text-zinc-900 dark:text-white">Total</dt>
                  <dd id="order-total" class="font-semibold text-zinc-900 dark:text-white">
                    {money(@order.total_cents, @order.currency)}
                  </dd>
                </div>
              </dl>

              <%= if @can_pay? do %>
                <.form
                  for={to_form(%{}, as: "order_payment")}
                  id="pay-form"
                  action={~p"/orders/#{@order.id}/pay"}
                  method="post"
                  class="mt-6"
                >
                  <button
                    id="pay-button"
                    type="submit"
                    class="w-full rounded-xl bg-brand-600 px-4 py-3 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-600"
                  >
                    Pay via Paystack · {money(@order.total_cents, @order.currency)}
                  </button>
                </.form>
              <% end %>

              <p class="mt-6 rounded-xl bg-zinc-50 p-4 text-xs leading-5 text-zinc-500 dark:bg-white/5 dark:text-zinc-400">
                Everything on this order was captured at the moment of purchase. When you
                pay, this order moves to <span class="font-medium text-zinc-600 dark:text-zinc-300">paid</span>;
                each line is then tracked as its own delivery, and your access is recorded
                once that delivery completes.
              </p>
            </div>
          </aside>
        </div>
      <% end %>
    </section>
    """
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:order_not_found, false)
    |> assign(:can_pay?, false)
    |> refresh_orders()
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Cass.Orders.get_order(socket.assigns.current_scope, id) do
      nil ->
        socket
        |> assign(:order_not_found, true)
        |> assign(:order, nil)
        |> assign(:can_pay?, false)

      order ->
        socket
        |> assign(:order_not_found, false)
        |> assign(:order, order)
        |> assign(:can_pay?, can_pay?(socket.assigns.current_scope, order))
        |> assign(:page_title, "#{order.number} · Orders · CASS Marketplace")
    end
  end

  defp can_pay?(scope, %Cass.Orders.Order{status: :awaiting_payment, user_id: user_id}) do
    case scope do
      %Cass.Accounts.Scope{user: %Cass.Accounts.User{id: ^user_id}} -> true
      _other -> false
    end
  end

  defp can_pay?(_scope, _order), do: false

  defp refresh_orders(socket) do
    stream(socket, :orders, Cass.Orders.list_orders(socket.assigns.current_scope), reset: true)
  end

  defp status_class(:awaiting_payment),
    do: "bg-zinc-100 text-zinc-700 dark:bg-white/10 dark:text-zinc-200"

  defp status_class(:paid),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"

  defp status_class(:processing),
    do: "bg-accent-50 text-accent-700 dark:bg-accent-500/10 dark:text-accent-300"

  defp status_class(:completed),
    do: "bg-emerald-50 text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-300"

  defp status_class(:cancelled), do: "bg-red-50 text-red-700 dark:bg-red-500/10 dark:text-red-300"
  defp status_class(:failed), do: "bg-red-50 text-red-700 dark:bg-red-500/10 dark:text-red-300"

  defp money(cents, currency) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{dollars}.#{remainder}"
  end

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%B %d, %Y")

  defp ok(socket), do: {:ok, socket}
end
