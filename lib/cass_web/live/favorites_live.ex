defmodule CassWeb.FavoritesLive do
  @moduledoc """
  The signed-in favorites page (`/favorites`).

  Lists the products the account has pinned, most recently saved first, each
  with a remove control. Products that stopped being publicly reachable simply
  drop out (see `Cass.Favorites.list_favorite_products/1`). The page is
  personal and `noindex`.
  """
  use CassWeb, :live_view

  alias Cass.Favorites
  alias CassWeb.ProductCard

  @impl true
  def mount(_params, _session, socket) do
    products = Favorites.list_favorite_products(socket.assigns.current_scope)

    socket
    |> assign(:favorites_empty?, products == [])
    |> assign(:favorite_products, Map.new(products, &{&1.id, &1}))
    |> stream(:products, products, dom_id: &"favorite-#{&1.id}")
    |> assign(:page_title, "Favorites · CASS Marketplace")
    |> assign(:meta_description, "Products you have saved in the CASS marketplace.")
    |> assign(:robots, "noindex, follow")
    |> ok()
  end

  # Removal needs the product struct again (to name it in the analytics event
  # and to let `stream_delete/3` derive the DOM id), and a `LiveStream` is not
  # enumerable server-side — so the loaded favorites are also kept as an
  # ordinary `id => product` map assign alongside the stream.
  @impl true
  def handle_event("remove-favorite", %{"product_id" => product_id}, socket) do
    with {id, ""} <- Integer.parse(product_id),
         {:ok, product} <- Map.fetch(socket.assigns.favorite_products, id) do
      Favorites.remove_favorite(socket.assigns.current_scope, product)

      CassWeb.LiveAnalytics.track(socket, "favorite_removed",
        path: ~p"/favorites",
        subject_type: "product",
        subject_id: product.id,
        metadata: %{"title" => product.name}
      )

      remaining = Map.delete(socket.assigns.favorite_products, id)

      {:noreply,
       socket
       |> assign(:favorite_products, remaining)
       |> assign(:favorites_empty?, map_size(remaining) == 0)
       |> stream_delete(:products, product)}
    else
      _other -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/favorites"}>
      <div class="flex items-end justify-between gap-4">
        <div>
          <p class="text-sm font-semibold tracking-wide text-brand-700 uppercase dark:text-brand-300">
            Saved items
          </p>
          <h1
            id="favorites-heading"
            class="mt-2 text-3xl font-bold tracking-tight text-zinc-900 dark:text-white"
          >
            Favorites
          </h1>
        </div>
      </div>

      <div
        id="favorites"
        phx-update="stream"
        class="mt-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3"
      >
        <div
          :if={@favorites_empty?}
          id="favorites-empty"
          class="rounded-2xl border border-dashed border-zinc-300 px-6 py-14 text-center sm:col-span-2 lg:col-span-3 dark:border-white/15"
        >
          <span class="mx-auto grid size-12 place-items-center rounded-full bg-brand-50 text-brand-600 dark:bg-brand-500/10 dark:text-brand-300">
            <.icon name="hero-heart" class="size-6" />
          </span>
          <h2 class="mt-4 text-lg font-semibold text-zinc-900 dark:text-white">
            No saved products yet
          </h2>
          <p class="mx-auto mt-1 max-w-sm text-sm leading-6 text-zinc-500 dark:text-zinc-400">
            Tap the heart on any product to pin it here for later.
          </p>
          <.link
            navigate={~p"/catalog"}
            class="mt-5 inline-flex items-center gap-2 rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700"
          >
            Browse the catalog <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>

        <div :for={{id, product} <- @streams.products} id={id} class="relative">
          <ProductCard.product_card product={product} />
          <button
            id={"favorite-remove-#{product.id}"}
            phx-click="remove-favorite"
            phx-value-product_id={product.id}
            aria-label={"Remove #{product.name} from favorites"}
            class="absolute top-3 right-3 grid size-9 place-items-center rounded-full border border-zinc-200 bg-white/90 text-zinc-500 shadow-sm backdrop-blur transition hover:border-rose-300 hover:text-rose-600 dark:border-white/15 dark:bg-[#0b0b14]/90 dark:text-zinc-400 dark:hover:border-rose-500/40 dark:hover:text-rose-400"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp ok(socket), do: {:ok, socket}
end
