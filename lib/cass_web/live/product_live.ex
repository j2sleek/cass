defmodule CassWeb.ProductLive do
  @moduledoc """
  The public product page (`/catalog/products/:slug`).

  Serves published products with `:public` or `:unlisted` visibility. Unlisted
  products are marked `noindex`. Drafts, archived items, `:private` products,
  products in non-active categories, and unknown slugs render the shared
  not-found state.
  """
  use CassWeb, :live_view

  alias Cass.Accounts.Scope
  alias Cass.Catalog.ProductType
  alias CassWeb.{Metadata, NotFound}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Cass.Catalog.get_public_product_by_slug(slug) do
      nil ->
        socket
        |> assign(:not_found, true)
        |> assign(:product, nil)
        |> assign(:page_title, "Product not found · CASS Marketplace")
        |> assign(:meta_description, "The requested product is not available.")
        |> assign(:robots, "noindex, follow")
        |> ok()

      product ->
        socket
        |> assign(:not_found, false)
        |> assign(:product, product)
        |> assign(
          :favorited?,
          Cass.Favorites.favorited?(socket.assigns.current_scope, product.id)
        )
        |> assign(:buy_form, build_buy_form(product.active_variants))
        |> assign(
          :default_sold_out?,
          sold_out?(default_variant(product.active_variants))
        )
        |> assign(:page_title, "#{Metadata.title(product)} · CASS Marketplace")
        |> assign(:meta_description, Metadata.product_description(product))
        |> assign(:canonical_url, CassWeb.Endpoint.url() <> ~p"/catalog/products/#{product.slug}")
        |> assign(:robots, robots(product.visibility))
        |> ok()
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Counted once per rendered product page (the `connected?/1` guard drops the
    # dead render). This covers both a direct landing and in-app navigation to a
    # product, since `handle_params/3` runs on every LiveView navigation.
    if connected?(socket) and socket.assigns[:product] do
      product = socket.assigns.product

      CassWeb.LiveAnalytics.track(socket, "product_view",
        path: ~p"/catalog/products/#{product.slug}",
        subject_type: "product",
        subject_id: product.id,
        metadata: %{
          "title" => product.name,
          "product_type" => product.product_type,
          "category" => product.category.name
        }
      )
    end

    {:noreply, socket}
  end

  # Flips the signed-in visitor's pin on this product. Guests cannot save: the
  # button they see is only rendered for authenticated scopes (`Scope.authenticated?/1`),
  # so this path is the guard of last resort, not the norm.
  @impl true
  def handle_event("toggle-favorite", _params, socket) do
    scope = socket.assigns.current_scope
    product = socket.assigns.product

    if Scope.authenticated?(scope) do
      currently = socket.assigns.favorited?

      result =
        if currently do
          Cass.Favorites.remove_favorite(scope, product)
        else
          Cass.Favorites.add_favorite(scope, product)
        end

      case result do
        {:ok, _favorite} ->
          {:noreply,
           socket |> assign(:favorited?, true) |> track_favorite("favorite_added", product)}

        :ok ->
          {:noreply,
           socket |> assign(:favorited?, false) |> track_favorite("favorite_removed", product)}

        {:error, _changeset} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/catalog"}>
      <%= if @not_found do %>
        <NotFound.not_found resource="product" />
      <% else %>
        <nav
          aria-label="Breadcrumb"
          class="flex items-center gap-1.5 text-xs font-medium text-zinc-500 dark:text-zinc-400"
        >
          <.link navigate={~p"/"} class="transition hover:text-brand-700 dark:hover:text-brand-300">
            Home
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <.link
            navigate={~p"/catalog"}
            class="transition hover:text-brand-700 dark:hover:text-brand-300"
          >
            Catalog
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <.link
            navigate={~p"/catalog/categories/#{@product.category.slug}"}
            class="transition hover:text-brand-700 dark:hover:text-brand-300"
          >
            {@product.category.name}
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <span class="text-zinc-600 dark:text-zinc-300">{@product.name}</span>
        </nav>

        <div class="mt-6 grid gap-10 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <div class="flex flex-wrap items-center gap-2">
              <span class="rounded-full bg-accent-50 px-2.5 py-1 text-xs font-semibold tracking-wide text-accent-700 uppercase dark:bg-accent-500/10 dark:text-accent-300">
                {product_type_label(@product.product_type)}
              </span>
              <%= if @product.visibility == :unlisted do %>
                <span class="rounded-full bg-zinc-100 px-2.5 py-1 text-xs font-medium text-zinc-600 dark:bg-white/10 dark:text-zinc-300">
                  Unlisted
                </span>
              <% end %>
            </div>

            <h1 class="mt-4 text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
              {@product.name}
            </h1>

            <%= if @product.short_description do %>
              <p class="mt-3 text-base leading-7 text-zinc-600 dark:text-zinc-300">
                {@product.short_description}
              </p>
            <% end %>

            <%= if @product.description do %>
              <div class="mt-8 whitespace-pre-line text-sm leading-7 text-zinc-600 dark:text-zinc-300">
                {@product.description}
              </div>
            <% end %>
          </div>

          <aside id="product-details" class="lg:col-span-1">
            <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-white/5">
              <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                Product details
              </h2>
              <dl class="mt-4 space-y-4 text-sm">
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Category</dt>
                  <dd>
                    <.link
                      navigate={~p"/catalog/categories/#{@product.category.slug}"}
                      class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-300"
                    >
                      {@product.category.name}
                    </.link>
                  </dd>
                </div>
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Delivery</dt>
                  <dd class="text-zinc-700 dark:text-zinc-200">
                    {ProductType.delivery_hint(@product.product_type)}
                  </dd>
                </div>
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Published</dt>
                  <dd class="text-zinc-700 dark:text-zinc-200">
                    {format_date(@product.published_at)}
                  </dd>
                </div>
              </dl>

              <%= if @buy_form do %>
                <%= if Scope.authenticated?(@current_scope) do %>
                  <div id="buy-panel" class="mt-6">
                    <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                      {product_type_label(@product.product_type)} purchase
                    </h2>
                    <p class="mt-1 text-sm font-semibold text-brand-700 dark:text-brand-300">
                      <span id="buy-unit-price">
                        {money(
                          default_variant(@product.active_variants).price_cents,
                          default_variant(@product.active_variants).currency
                        )}
                      </span>
                      <span class="font-normal text-zinc-500 dark:text-zinc-400">
                        each · prices and stock verified at checkout
                      </span>
                    </p>
                    <p
                      id="buy-stock-note"
                      class={[
                        "mt-1 text-sm font-medium text-amber-700 dark:text-amber-400",
                        !@default_sold_out? && "hidden"
                      ]}
                    >
                      This option is out of stock right now.
                    </p>

                    <.form
                      for={@buy_form}
                      id="buy-form"
                      action={~p"/orders"}
                      method="post"
                      class="mt-4"
                    >
                      <.input
                        field={@buy_form[:product_variant_id]}
                        type="select"
                        name="product_variant_id"
                        label="Variant"
                        options={variant_options(@product.active_variants)}
                        phx-hook=".VariantPrice"
                        data-options={variant_price_data(@product.active_variants)}
                      />
                      <.input
                        field={@buy_form[:quantity]}
                        type="number"
                        name="quantity"
                        label="Quantity"
                        step="1"
                        min="1"
                        max={Cass.Orders.OrderItem.max_quantity()}
                      />
                      <button
                        id="buy-button"
                        type="submit"
                        disabled={@default_sold_out?}
                        class="mt-4 w-full rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-60"
                      >
                        Buy now
                      </button>
                    </.form>
                  </div>

                  <script :type={Phoenix.LiveView.ColocatedHook} name=".VariantPrice">
                    export default {
                      mounted() {
                        this.applyState();
                        this.el.addEventListener("change", () => this.applyState());
                      },
                      applyState() {
                        const options = JSON.parse(this.el.dataset.options || "[]");
                        const selected = options.find(
                          (option) => option.id === this.el.value
                        );
                        if (!selected) return;
                        const panel = this.el.closest("#buy-panel");
                        if (!panel) return;
                        const unitPrice = panel.querySelector("#buy-unit-price");
                        const stockNote = panel.querySelector("#buy-stock-note");
                        const button = panel.querySelector("#buy-button");
                        const soldOut = selected.stock === 0;
                        if (unitPrice) unitPrice.textContent = `${selected.price}`;
                        if (stockNote) stockNote.classList.toggle("hidden", !soldOut);
                        if (button) button.disabled = soldOut;
                      },
                    };
                  </script>
                <% else %>
                  <div
                    id="buy-sign-in"
                    class="mt-6 rounded-xl bg-zinc-50 p-4 text-xs leading-5 text-zinc-500 dark:bg-white/5 dark:text-zinc-400"
                  >
                    Sign in to buy this product.
                    <.link
                      navigate={~p"/users/log-in"}
                      id="product-log-in-link"
                      class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-300"
                    >
                      Log in
                    </.link>
                  </div>
                <% end %>
              <% else %>
                <div class="mt-6 rounded-xl bg-zinc-50 p-4 text-xs leading-5 text-zinc-500 dark:bg-white/5 dark:text-zinc-400">
                  This product has no purchase options yet — check back soon.
                </div>
              <% end %>

              <%= if Scope.authenticated?(@current_scope) do %>
                <div class="mt-6 border-t border-zinc-100 pt-4 dark:border-white/10">
                  <button
                    id="favorite-toggle"
                    type="button"
                    phx-click="toggle-favorite"
                    aria-pressed={to_string(@favorited?)}
                    class={[
                      "flex w-full items-center justify-center gap-2 rounded-xl border px-4 py-2.5 text-sm font-semibold transition active:scale-[0.99]",
                      if(@favorited?,
                        do:
                          "border-brand-200 bg-brand-50 text-brand-700 hover:bg-brand-100 dark:border-brand-500/30 dark:bg-brand-500/10 dark:text-brand-300 dark:hover:bg-brand-500/20",
                        else:
                          "border-zinc-200 bg-white text-zinc-600 hover:border-brand-300 hover:text-brand-700 dark:border-white/15 dark:bg-white/5 dark:text-zinc-300 dark:hover:border-brand-500/40 dark:hover:text-brand-300"
                      )
                    ]}
                  >
                    <.icon
                      name={if(@favorited?, do: "hero-heart-solid", else: "hero-heart")}
                      class="size-4"
                    />
                    {if(@favorited?, do: "Saved to favorites", else: "Save to favorites")}
                  </button>
                </div>
              <% end %>
            </div>
          </aside>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp product_type_label(product_type), do: ProductType.label(product_type)

  defp robots(:unlisted), do: "noindex, follow"
  defp robots(_visibility), do: nil

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%B %d, %Y")
  defp format_date(_), do: "TBA"

  defp build_buy_form([first_variant | _rest]) do
    to_form(%{"product_variant_id" => first_variant.id, "quantity" => "1"}, as: :buy)
  end

  defp build_buy_form(_no_variants), do: nil

  defp default_variant([first_variant | _rest]), do: first_variant
  defp default_variant([]), do: nil

  defp sold_out?(nil), do: false
  defp sold_out?(%{stock: stock}), do: is_nil(stock) or stock == 0

  defp variant_options(variants) do
    Enum.map(variants, fn variant ->
      label =
        "#{variant.name} — #{money(variant.price_cents, variant.currency)}" <>
          if(sold_out?(variant), do: " (out of stock)", else: "")

      {label, variant.id}
    end)
  end

  # The hook reads this JSON to mirror the selection client-side: unit price,
  # sold-out note, and the disabled Buy button all track the chosen variant.
  defp variant_price_data(variants) do
    variants
    |> Enum.map(fn variant ->
      %{
        "id" => to_string(variant.id),
        "price" => money(variant.price_cents, variant.currency),
        "stock" => variant.stock || 0
      }
    end)
    |> Jason.encode!()
  end

  defp money(cents, currency) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{dollars}.#{remainder}"
  end

  defp track_favorite(socket, name, product) do
    CassWeb.LiveAnalytics.track(socket, name,
      path: ~p"/catalog/products/#{product.slug}",
      subject_type: "product",
      subject_id: product.id,
      metadata: %{"title" => product.name}
    )

    socket
  end

  defp ok(socket), do: {:ok, socket}
end
