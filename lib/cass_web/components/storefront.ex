defmodule CassWeb.Storefront do
  @moduledoc """
  Shared storefront chrome: the search box, the category rail, section
  headings, result/sort controls, pagination and empty states.

  These are presentational only. In particular nothing here decides what is
  visible to a visitor — the category list always comes from
  `Cass.Catalog.list_public_categories/0` and the product list from a
  public-only query, so this module has no way to widen what a page shows.
  """
  use CassWeb, :html

  alias Cass.Catalog.SearchParams

  @default_per_page 24

  @category_icons [
    "hero-squares-2x2",
    "hero-book-open",
    "hero-tag",
    "hero-cube",
    "hero-sparkles",
    "hero-rocket-launch"
  ]

  @doc """
  A real GET search form targeting the catalog.

  It is a plain `<form>` rather than `<.form>` on purpose: a GET form must
  submit `?query=…`, and `<.form>` would namespace the field into
  `query[query]`. Being a genuine GET form also means search works with
  JavaScript disabled and produces a shareable, crawlable URL.

  The input is a search input with a visually hidden `<label>`, so it is
  announced correctly, and it carries `aria-describedby` pointing at the
  result-count region when one is present.
  """
  attr :id, :string, default: "storefront-search-form"
  attr :value, :string, default: nil
  attr :placeholder, :string, default: "Search products and services"
  attr :label, :string, default: "Search the CASS catalog"
  attr :described_by, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def search_form(assigns) do
    ~H"""
    <form
      id={@id}
      action={~p"/catalog"}
      method="get"
      role="search"
      aria-label={@label}
      class={["relative", @class]}
      {@rest}
    >
      <label for={"#{@id}-input"} class="sr-only">{@label}</label>
      <.icon
        name="hero-magnifying-glass"
        class="pointer-events-none absolute top-1/2 left-3.5 size-4 -translate-y-1/2 text-zinc-400"
      />
      <input
        type="search"
        id={"#{@id}-input"}
        name="query"
        value={@value}
        placeholder={@placeholder}
        aria-describedby={@described_by}
        autocomplete="off"
        class="w-full rounded-xl border border-zinc-300 bg-white py-2.5 pr-3 pl-10 text-sm text-zinc-900 shadow-sm transition placeholder:text-zinc-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/30 focus:outline-none dark:border-white/15 dark:bg-white/5 dark:text-white dark:placeholder:text-zinc-500"
      />
      <button
        type="submit"
        class="sr-only"
      >
        Search
      </button>
    </form>
    """
  end

  @doc """
  The horizontal category rail.

  `categories` is a list of root categories with their `:children` preloaded.
  Rendered as a single labelled `<nav>` of links so keyboard and screen-reader
  users can move through the taxonomy as ordinary links, not as a carousel.
  """
  attr :id, :string, default: "category-rail"
  attr :categories, :list, required: true
  attr :active_slug, :string, default: nil
  attr :label, :string, default: "Product categories"

  def category_rail(assigns) do
    ~H"""
    <nav id={@id} aria-label={@label} class="scroll-mt-24">
      <ul class="-mx-4 flex snap-x snap-mandatory gap-2 overflow-x-auto px-4 pb-2 sm:mx-0 sm:flex-wrap sm:overflow-visible sm:px-0">
        <li :for={category <- @categories} class="snap-start">
          <.link
            patch={category_path(category, @active_slug)}
            aria-current={if(@active_slug == category.slug, do: "page", else: nil)}
            class={[
              "inline-flex items-center gap-2 rounded-full border px-3.5 py-2 text-sm font-medium whitespace-nowrap transition",
              "focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:outline-none",
              if(@active_slug == category.slug,
                do: "border-brand-600 bg-brand-600 text-white shadow-sm hover:bg-brand-700",
                else:
                  "border-zinc-200 bg-white text-zinc-700 hover:border-brand-300 hover:text-brand-800 hover:bg-brand-50/60 dark:border-white/10 dark:bg-white/5 dark:text-zinc-200 dark:hover:border-brand-500/40 dark:hover:bg-white/10"
              )
            ]}
          >
            <.icon name={category_icon(category.id)} class="size-4 shrink-0" />
            {category.name}
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  defp category_path(category, nil), do: ~p"/catalog/categories/#{category.slug}"
  defp category_path(_category, _active), do: ~p"/catalog"

  @doc """
  A section heading with an optional trailing action slot.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil

  slot :action

  def section_heading(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-end justify-between gap-3", @class]}>
      <div>
        <h2 id={@id} class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          {@title}
        </h2>
        <p :if={@subtitle} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {@subtitle}
        </p>
      </div>
      <div :if={@action != []}>{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  The shared empty state.

  The `only:` utility on the container means it is shown exactly when it is the
  only child, which is how a LiveView stream signals an empty collection
  without also tracking a separate count.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, default: nil
  attr :icon, :string, default: "hero-squares-2x2"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="col-span-full hidden rounded-2xl border border-dashed border-zinc-300 p-10 text-center only:block dark:border-white/15"
    >
      <span class="mx-auto grid size-11 place-items-center rounded-xl bg-zinc-100 text-zinc-400 dark:bg-white/10 dark:text-zinc-500">
        <.icon name={@icon} class="size-5" />
      </span>
      <p class="mt-4 text-sm font-semibold text-zinc-900 dark:text-white">{@title}</p>
      <p
        :if={@body}
        class="mx-auto mt-1.5 max-w-sm text-sm leading-6 text-zinc-500 dark:text-zinc-400"
      >
        {@body}
      </p>
    </div>
    """
  end

  @doc """
  Result count plus the sort menu and product-type filter.

  Every control is a link, not a form post, so each arrangement of results has
  its own URL and is reachable without JavaScript. `params` carries the current
  `%SearchParams{}` so filters are preserved when only the sort changes.
  """
  attr :id, :string, default: "catalog-results-bar"
  attr :total, :integer, required: true
  attr :params, :any, required: true
  attr :show_type_filter, :boolean, default: true
  attr :class, :string, default: nil

  def results_bar(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-col gap-4", @class]}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p class="text-sm text-zinc-600 dark:text-zinc-300" aria-live="polite">
          <span class="font-semibold text-zinc-900 dark:text-white">{@total}</span>
          {pluralize(@total, "product", "products")}
          <span :if={@params.query}> for <span class="font-semibold">“{@params.query}”</span></span>
        </p>

        <div class="flex items-center gap-2">
          <label for="catalog-sort" class="sr-only">Sort products</label>
          <div class="relative">
            <select
              id="catalog-sort"
              class="appearance-none rounded-xl border border-zinc-300 bg-white py-2 pr-8 pl-3 text-sm font-medium text-zinc-700 transition hover:border-brand-300 focus:border-brand-500 focus:ring-2 focus:ring-brand-500/30 focus:outline-none dark:border-white/15 dark:bg-white/5 dark:text-zinc-200"
              phx-change="sort"
            >
              <option
                :for={sort <- SearchParams.sorts()}
                value={sort}
                selected={sort == @params.sort}
              >
                {SearchParams.sort_label(sort)}
              </option>
            </select>
            <.icon
              name="hero-chevron-down"
              class="pointer-events-none absolute top-1/2 right-2.5 size-4 -translate-y-1/2 text-zinc-400"
            />
          </div>
        </div>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div
          :if={@show_type_filter}
          class="flex flex-wrap gap-2"
          role="group"
          aria-label="Filter by product type"
        >
          <.link
            patch={~p"/catalog?#{catalog_query(@params, product_type: nil, page: nil)}"}
            aria-current={if(is_nil(@params.product_type), do: "true", else: nil)}
            class={filter_chip_classes(is_nil(@params.product_type))}
          >
            All types
          </.link>
          <.link
            :for={type <- Cass.Catalog.product_types()}
            patch={~p"/catalog?#{catalog_query(@params, product_type: type, page: nil)}"}
            aria-current={if(@params.product_type == type, do: "true", else: nil)}
            class={filter_chip_classes(@params.product_type == type)}
          >
            {CassWeb.Format.product_type_label(type)}
          </.link>
        </div>

        <.link
          :if={filters_active?(@params)}
          patch={clear_filters_path()}
          id="clear-filters"
          class="inline-flex items-center gap-1 text-xs font-semibold text-zinc-500 underline decoration-zinc-300 underline-offset-4 transition hover:text-brand-700 hover:decoration-brand-300 dark:text-zinc-400 dark:decoration-white/20 dark:hover:text-brand-300"
        >
          <.icon name="hero-x-mark" class="size-3.5" /> Clear filters
        </.link>
      </div>
    </div>
    """
  end

  # Anything other than the default arrangement counts as "filtered", including
  # a non-default sort, so the escape hatch is offered exactly when it can help.
  defp filters_active?(%{query: nil, product_type: nil, category_slug: nil, sort: "newest"}),
    do: false

  defp filters_active?(_params), do: true

  @doc """
  Pagination for a paged result set.

  Rendered as a labelled `<nav>` of links with `aria-current="page"` on the
  active page, and omitted entirely for a single page so short result sets are
  not cluttered. Disabled ends are real anchors carrying `aria-disabled`
  (rather than `href="#"`), so there is no focusable control that does nothing.
  """
  attr :id, :string, default: "catalog-pagination"
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :params, :any, required: true
  attr :label, :string, default: "Pagination"

  def pagination(assigns) do
    assigns = assign(assigns, :entries, page_entries(assigns.page, assigns.total_pages))

    ~H"""
    <nav
      :if={@total_pages > 1}
      id={@id}
      aria-label={@label}
      class="mt-10 flex items-center justify-center gap-1"
    >
      <.link
        patch={~p"/catalog?#{catalog_query(@params, page: max(@page - 1, 1))}"}
        aria-disabled={to_string(@page <= 1)}
        class={page_link_classes(@page <= 1)}
        aria-label="Previous page"
      >
        <.icon name="hero-chevron-left" class="size-4" />
      </.link>

      <%= for entry <- @entries do %>
        <span
          :if={not entry.link?}
          aria-hidden="true"
          class="px-1 text-sm text-zinc-400 dark:text-zinc-500"
        >
          {entry.label}
        </span>
        <.link
          :if={entry.link?}
          patch={~p"/catalog?#{catalog_query(@params, page: entry.number)}"}
          aria-current={entry.aria_current}
          aria-label={entry.aria_label}
          class={page_link_classes(false, entry.current)}
        >
          {entry.label}
        </.link>
      <% end %>

      <.link
        patch={~p"/catalog?#{catalog_query(@params, page: min(@page + 1, @total_pages))}"}
        aria-disabled={to_string(@page >= @total_pages)}
        class={page_link_classes(@page >= @total_pages)}
        aria-label="Next page"
      >
        <.icon name="hero-chevron-right" class="size-4" />
      </.link>
    </nav>
    """
  end

  @doc """
  Builds the query map for a catalog link, dropping empty values.

  Returning only the keys that are actually set keeps URLs clean and, more
  importantly, means a "reset" of one control does not resurrect another.
  """
  def catalog_query(params, overrides \\ [])

  def catalog_query(%SearchParams{} = params, overrides) do
    merged =
      %{
        query: params.query,
        type: params.product_type,
        sort: params.sort,
        category: params.category_slug,
        page: params.page,
        per_page: params.per_page
      }
      |> Map.merge(Map.new(overrides))
      # nil means "unset this control"; page 1, the default sort and the default
      # page size are all implied, so they are left out of the URL.
      |> Enum.reject(fn {key, value} ->
        is_nil(value) or
          (key == :page and value == 1) or
          (key == :sort and value == "newest") or
          (key == :per_page and value == @default_per_page)
      end)
      |> Map.new()

    merged
  end

  @doc "A `\"from\"`-`\"to\"` result range label, e.g. `Showing 1–24 of 130`."
  def range_label(%{total: 0}), do: "Showing no results"

  def range_label(%{total: total, page: page, per_page: per_page}) do
    first = (page - 1) * per_page + 1
    last = min(page * per_page, total)
    "Showing #{first}–#{last} of #{total}"
  end

  @doc "Clears all filters and returns to the plain newest-first catalog."
  def clear_filters_path, do: ~p"/catalog"

  @doc "A small dismissible notice, used by the sort control on narrow screens."
  attr :id, :string, required: true
  attr :message, :string, required: true
  slot :inner_block

  def notice(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="flex items-start gap-3 rounded-xl border border-brand-200 bg-brand-50 p-4 text-sm text-brand-900 dark:border-brand-800 dark:bg-brand-950 dark:text-brand-100"
    >
      <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
      <div class="flex-1">{render_slot(@inner_block) || @message}</div>
    </div>
    """
  end

  defp filter_chip_classes(active?) do
    [
      "rounded-full border px-3 py-1.5 text-xs font-semibold transition focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:outline-none",
      if(active?,
        do: "border-brand-600 bg-brand-600 text-white hover:bg-brand-700",
        else:
          "border-zinc-200 bg-white text-zinc-600 hover:border-brand-300 hover:text-brand-800 dark:border-white/10 dark:bg-white/5 dark:text-zinc-300 dark:hover:border-brand-500/40"
      )
    ]
  end

  defp page_link_classes(disabled?, active? \\ false)

  defp page_link_classes(true, _active?) do
    "pointer-events-none rounded-lg border border-zinc-100 px-3 py-2 text-sm text-zinc-300 dark:border-white/5 dark:text-zinc-600"
  end

  defp page_link_classes(false, true) do
    "rounded-lg border border-brand-600 bg-brand-600 px-3.5 py-2 text-sm font-semibold text-white shadow-sm"
  end

  defp page_link_classes(false, false) do
    "rounded-lg border border-zinc-200 bg-white px-3.5 py-2 text-sm font-medium text-zinc-700 transition hover:border-brand-300 hover:bg-brand-50 hover:text-brand-800 dark:border-white/10 dark:bg-white/5 dark:text-zinc-200 dark:hover:border-brand-500/40"
  end

  # A short window around the current page. The first two and last two pages
  # are always reachable so a shopper is never stranded on an interior page.
  defp page_entries(page, total) when total <= 7,
    do: Enum.map(1..total, &number_entry(&1, page))

  defp page_entries(page, total) do
    kept = Enum.filter(1..total, &(&1 <= 2 or &1 >= total - 1 or abs(&1 - page) <= 1))

    Enum.flat_map(kept, fn number ->
      previous = number - 1

      # A skipped run becomes an inert ellipsis rather than a link, so there is
      # no focusable control that leads somewhere unhelpful.
      if previous >= 1 and previous not in kept do
        [gap_entry(), number_entry(number, page)]
      else
        [number_entry(number, page)]
      end
    end)
  end

  defp number_entry(number, page) do
    current? = number == page

    %{
      number: number,
      label: Integer.to_string(number),
      link?: true,
      current: current?,
      aria_current: if(current?, do: "page"),
      aria_label: if(current?, do: "Page #{number}, current page", else: "Page #{number}")
    }
  end

  defp gap_entry do
    %{number: 0, label: "…", link?: false, current: false, aria_current: nil, aria_label: nil}
  end

  @doc """
  A stable decorative icon for a category, chosen from its id.

  Deterministic so a given category keeps the same icon across renders and
  across pages, rather than shifting as the list grows.
  """
  def category_icon(id), do: Enum.at(@category_icons, rem(id, length(@category_icons)))

  defp pluralize(count, singular, plural), do: if(count == 1, do: singular, else: plural)
end
