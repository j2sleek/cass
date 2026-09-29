defmodule CassWeb.ProductManagementLive do
  @moduledoc """
  The protected product management area (`/manage/products`).

  This is the smallest real surface that can exercise Milestone 3 Phase 3 end to
  end. It exists to prove the authorization boundary, not to be a seller
  dashboard: there is no transfer UI, no pricing, no orders, and no vendor
  onboarding.

  Two independent layers guard it, and neither trusts the other:

    * the route is gated by `CassWeb.UserAuth`'s `:require_vendor_or_admin_user`
      plug and the matching `on_mount` hook, so a guest is sent to log in and a
      plain customer is refused before any product is loaded;
    * every action re-resolves the product through
      `Cass.Catalog.get_managed_product/2` with the socket's `current_scope`,
      which returns `nil` for a product the caller may not manage. A tampered
      product id in an event payload therefore resolves to nothing and the page
      falls back to the not-found state, exactly as a guessed URL would.

  Ownership is never read from the client. Creation calls
  `Cass.Catalog.create_owned_product/3`, which derives the owner from the
  authenticated scope, so a hidden `owner_id` input is neither needed nor
  honoured. The category *is* a client choice, but only as a selector: the form
  posts an id that is resolved to a `%Category{}` row before it reaches the
  context.
  """
  use CassWeb, :live_view

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias CassWeb.NotFound

  @product_types [
    {"Digital", "digital"},
    {"SMM", "smm"},
    {"AI", "ai"},
    {"Service", "service"}
  ]

  @visibilities [
    {"Public — listed and indexable", "public"},
    {"Unlisted — reachable by link only", "unlisted"},
    {"Private — not publicly reachable", "private"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket
    # Configured once, here: a stream cannot be reconfigured after it is streamed,
    # and the dom id is what tests and CSS anchor on.
    |> stream_configure(:products, dom_id: &"product-#{&1.id}")
    |> assign(:page_title, "Manage products · CASS Marketplace")
    |> assign(:meta_description, "Create and manage your products.")
    |> assign(:robots, "noindex, nofollow")
    |> assign(:categories, Catalog.list_categories())
    |> assign(:category_id, nil)
    |> assign(:product, nil)
    |> assign(:form, nil)
    |> assign(:category_error, nil)
    |> assign(:product_not_found, false)
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("validate", params, socket) do
    case new_product_category(socket, params) do
      nil ->
        {:noreply, missing_category(socket)}

      category ->
        {:noreply, assign_new_form(socket, category, params, action: :validate)}
    end
  end

  def handle_event("save", params, socket) do
    case new_product_category(socket, params) do
      nil ->
        {:noreply, missing_category(socket)}

      category ->
        scope = socket.assigns.current_scope

        case Catalog.create_owned_product(scope, category, product_params(params)) do
          {:ok, product} ->
            {:noreply,
             socket
             |> put_flash(:info, "Created \"#{product.name}\".")
             |> push_patch(to: ~p"/manage/products")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("validate_product", params, socket) do
    with_managed_product(socket, params, fn product ->
      scope = socket.assigns.current_scope

      changeset = form_changeset(Catalog.change_product(scope, product, product_params(params)))

      assign(socket, form: to_form(changeset, action: :validate))
    end)
  end

  def handle_event("update_product", params, socket) do
    with_managed_product(socket, params, fn product ->
      scope = socket.assigns.current_scope

      case Catalog.update_product(scope, product, product_params(params)) do
        {:ok, updated} ->
          changeset = form_changeset(Catalog.change_product(scope, updated, %{}))

          socket
          |> put_flash(:info, "Saved \"#{updated.name}\".")
          |> assign(form: to_form(changeset))

        {:error, changeset} ->
          assign(socket, form: to_form(changeset))
      end
    end)
  end

  def handle_event("publish_product", params, socket) do
    with_managed_product(socket, params, fn product ->
      scope = socket.assigns.current_scope

      case Catalog.publish_product(scope, product) do
        {:ok, published} ->
          socket
          |> put_flash(:info, "Published \"#{published.name}\".")
          |> refresh_products(scope)

        {:error, changeset} ->
          assign(socket, form: to_form(changeset))
      end
    end)
  end

  def handle_event("archive_product", params, socket) do
    with_managed_product(socket, params, fn product ->
      scope = socket.assigns.current_scope

      case Catalog.archive_product(scope, product) do
        {:ok, archived} ->
          socket
          |> put_flash(:info, "Archived \"#{archived.name}\".")
          |> refresh_products(scope)

        {:error, changeset} ->
          assign(socket, form: to_form(changeset))
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @product_not_found do %>
        <NotFound.not_found resource="product" />
      <% else %>
        <section class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
          <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
            Manage products
          </h1>
          <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
            Products you create here belong to your account, and you publish and archive them.
            Platform products belong to CASS and are managed by platform admins.
          </p>
        </section>

        <%= if @live_action == :index do %>
          <.manage_index
            products={@streams.products}
            current_scope={@current_scope}
            admin?={Scope.admin?(@current_scope)}
          />
        <% else %>
          <.manage_form
            action={@live_action}
            categories={@categories}
            category_id={@category_id}
            form={@form}
            product={@product}
            current_scope={@current_scope}
            category_error={@category_error}
            product_types={product_types()}
            visibilities={visibilities()}
          />
        <% end %>
      <% end %>
    </Layouts.app>
    """
  end

  attr :products, :any, required: true
  attr :current_scope, :map, required: true
  attr :admin?, :boolean, required: true

  defp manage_index(assigns) do
    ~H"""
    <section id="manage-products" class="pt-8">
      <div class="flex items-center justify-between gap-4">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Products
        </h2>
        <.link
          id="new-product-link"
          patch={~p"/manage/products/new"}
          class="inline-flex items-center gap-2 rounded-xl bg-brand-600 px-3.5 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700"
        >
          <.icon name="hero-plus" class="size-4" /> New product
        </.link>
      </div>

      <p id="manage-scope-note" class="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
        {if @admin? do
          "As an admin you can see and manage every product, including platform products."
        else
          "You can see and manage the products you own."
        end}
      </p>

      <ul
        id="product-list"
        phx-update="stream"
        class="mt-5 space-y-3"
      >
        <div
          :for={{dom_id, product} <- @products}
          id={dom_id}
          class="flex flex-col gap-4 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:border-brand-300 hover:shadow-md sm:flex-row sm:items-center sm:justify-between dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class={[
                "rounded-full px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide uppercase",
                status_class(product.status)
              ]}>
                {product.status}
              </span>
              <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-medium text-zinc-500 dark:bg-white/10 dark:text-zinc-300">
                {product.visibility}
              </span>
              <span
                id={"owner-#{product.id}"}
                class="rounded-full bg-accent-50 px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide text-accent-700 uppercase dark:bg-accent-500/10 dark:text-accent-300"
              >
                {owner_label(product, @admin?)}
              </span>
            </div>
            <p class="mt-2 truncate text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
              {product.name}
            </p>
            <p class="mt-0.5 truncate text-xs text-zinc-500 dark:text-zinc-400">
              /{product.slug} · {product.category.name}
            </p>
          </div>

          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <.link
              patch={~p"/manage/products/#{product}/edit"}
              class="rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:text-zinc-200 dark:hover:border-brand-400"
            >
              Edit
            </.link>
            <.form
              for={to_form(%{}, as: "publish")}
              id={"publish-product-#{product.id}"}
              phx-submit="publish_product"
              phx-value-id={product.id}
            >
              <button
                id={"publish-product-button-#{product.id}"}
                type="submit"
                disabled={product.status != :draft}
                class={[
                  "rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition dark:border-white/10 dark:text-zinc-200",
                  product.status == :draft && "cursor-not-allowed opacity-40",
                  product.status != :draft && "hover:border-brand-300 hover:text-brand-700"
                ]}
              >
                Publish
              </button>
            </.form>
            <.form
              for={to_form(%{}, as: "archive")}
              id={"archive-product-#{product.id}"}
              phx-submit="archive_product"
              phx-value-id={product.id}
            >
              <button
                id={"archive-product-button-#{product.id}"}
                type="submit"
                disabled={product.status == :archived}
                class={[
                  "rounded-lg border border-zinc-200 px-3 py-1.5 text-sm font-medium text-zinc-700 transition dark:border-white/10 dark:text-zinc-200",
                  product.status == :archived && "cursor-not-allowed opacity-40",
                  product.status != :archived && "hover:border-red-300 hover:text-red-600"
                ]}
              >
                Archive
              </button>
            </.form>
          </div>
        </div>

        <div
          id="product-list-empty"
          class="hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-400 only:block dark:border-white/10"
        >
          No products yet. Create your first one to get started.
        </div>
      </ul>
    </section>
    """
  end

  attr :action, :atom, required: true
  attr :categories, :list, required: true
  attr :category_id, :any, required: true
  attr :form, :any, required: true
  attr :product, :any, required: true
  attr :current_scope, :map, required: true
  attr :category_error, :any, required: true
  attr :product_types, :list, required: true
  attr :visibilities, :list, required: true

  defp manage_form(assigns) do
    ~H"""
    <section id="product-form-section" class="pt-8">
      <h2
        id="product-form-heading"
        class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white"
      >
        {if @action == :new, do: "New product", else: "Edit product"}
      </h2>

      <p
        :if={@action == :new}
        id="ownership-note"
        class="mt-3 flex items-start gap-2 rounded-xl bg-brand-50 p-3 text-sm text-brand-900 dark:bg-brand-500/10 dark:text-brand-200"
      >
        <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
        <span>
          This product will be owned by {scope_label(@current_scope)}. Ownership comes from
          your signed-in account and cannot be set from this form.
        </span>
      </p>

      <p
        :if={@categories == []}
        id="no-categories"
        class="mt-4 rounded-xl bg-zinc-100 p-4 text-sm text-zinc-600 dark:bg-white/5 dark:text-zinc-300"
      >
        A category is required before a product can be created. Seed the catalog or add a
        category from the console first.
      </p>

      <.form
        :if={@form}
        for={@form}
        id="product-form"
        phx-change={if @action == :new, do: "validate", else: "validate_product"}
        phx-submit={if @action == :new, do: "save", else: "update_product"}
        class="mt-5 max-w-xl space-y-1 rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-white/5"
      >
        <input
          type="hidden"
          name="product_id"
          id="product-id"
          value={@product && @product.id}
        />

        <%= if @action == :new do %>
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:slug]} type="text" label="Slug" />
          <.input
            field={@form[:product_type]}
            type="select"
            label="Product type"
            options={@product_types}
            prompt="Choose a type"
          />
          <.input
            field={@form[:visibility]}
            type="select"
            label="Visibility"
            options={@visibilities}
            prompt="Choose visibility"
          />

          <div class="fieldset mb-2">
            <label for="category_id">
              <span class="label mb-1">Category</span>
              <select
                id="category_id"
                name="category_id"
                class="w-full select"
              >
                <option value="">Choose a category</option>
                {Phoenix.HTML.Form.options_for_select(
                  Enum.map(@categories, &{&1.name, &1.id}),
                  Phoenix.HTML.Form.normalize_value("select", @category_id)
                )}
              </select>
            </label>
            <p
              :if={@category_error}
              id="category-error"
              class="mt-1 text-sm text-red-600 dark:text-red-400"
            >
              {@category_error}
            </p>
          </div>
        <% else %>
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:short_description]} type="text" label="Short description" />
          <.input
            field={@form[:visibility]}
            type="select"
            label="Visibility"
            options={@visibilities}
          />
        <% end %>

        <div class="mt-4 flex items-center gap-3">
          <button
            id="save-product"
            type="submit"
            class="rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700"
          >
            {if @action == :new, do: "Create product", else: "Save changes"}
          </button>
          <.link
            patch={~p"/manage/products"}
            class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:text-zinc-900 dark:text-zinc-300"
          >
            Cancel
          </.link>
        </div>
      </.form>
    </section>
    """
  end

  defp apply_action(socket, :index, _params) do
    refresh_products(socket, socket.assigns.current_scope)
  end

  defp apply_action(socket, :new, _params) do
    socket = assign(socket, product_not_found: false, product: nil)

    case socket.assigns.categories do
      [category | _rest] ->
        socket
        |> assign(:category_id, category.id)
        |> assign_new_form(category, %{})

      [] ->
        assign(socket, form: nil, category_id: nil)
    end
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Catalog.get_managed_product(scope, id) do
      nil ->
        assign(socket, product_not_found: true, product: nil, form: nil)

      product ->
        socket
        |> assign(:product_not_found, false)
        |> assign(:product, product)
        |> assign(
          :form,
          to_form(form_changeset(Catalog.change_product(scope, product, %{})))
        )
    end
  end

  defp assign_new_form(socket, category, params, opts \\ []) do
    scope = socket.assigns.current_scope

    changeset =
      form_changeset(Catalog.change_owned_product(scope, category, product_params(params)))

    assign(socket, :form, to_form(changeset, opts))
    |> assign(:category_error, nil)
  end

  defp refresh_products(socket, scope) do
    stream(socket, :products, Catalog.list_managed_products(scope), reset: true)
  end

  # Re-resolving the product on every event is what makes a tampered id useless:
  # an id belonging to another seller resolves to `nil` and the page falls back
  # to the not-found state. `Cass.Catalog.update_product/3` and its siblings
  # refuse the same product even if this lookup were bypassed, so neither layer
  # depends on the other.
  defp with_managed_product(socket, params, fun) do
    case Catalog.get_managed_product(socket.assigns.current_scope, managed_product_id(params)) do
      nil -> {:noreply, assign(socket, :product_not_found, true)}
      product -> {:noreply, fun.(product)}
    end
  end

  # The edit form posts a hidden `product_id`; the publish and archive forms are
  # `phx-value-id` buttons, so they post `id`. Both name the same thing and both
  # are re-resolved, so a tampered value is equally useless in either place.
  defp managed_product_id(params) do
    Map.get(params, "product_id") || Map.get(params, "id")
  end

  defp new_product_category(socket, params) do
    case Map.get(params, "category_id", socket.assigns.category_id) do
      nil -> nil
      "" -> nil
      category_id -> Catalog.get_category(category_id)
    end
  end

  # The category is a selector rather than a changeset field, so its error is
  # kept beside the form instead of inside it: `Phoenix.HTML.Form` does not carry
  # `:base` errors, and the form would look inert without this.
  defp missing_category(socket) do
    socket
    |> assign(:form, to_form(Ecto.Changeset.change(%Catalog.Product{})))
    |> assign(:category_error, "please choose a category")
  end

  defp product_types, do: @product_types
  defp visibilities, do: @visibilities

  defp product_params(%{"product" => %{"_action" => _action} = params}), do: params
  defp product_params(%{"product" => params}) when is_map(params), do: params
  defp product_params(_params), do: %{}

  defp form_changeset({_result, changeset}), do: changeset

  defp owner_label(%Catalog.Product{owner: nil}, _admin?), do: "Platform"
  defp owner_label(%Catalog.Product{}, true), do: "Seller"
  defp owner_label(%Catalog.Product{}, false), do: "Yours"

  defp scope_label(%Scope{user: %{email: email}}), do: email
  defp scope_label(_scope), do: "your account"

  defp status_class(:draft),
    do: "bg-zinc-100 text-zinc-600 dark:bg-white/10 dark:text-zinc-300"

  defp status_class(:published),
    do: "bg-brand-50 text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"

  defp status_class(:archived),
    do: "bg-red-50 text-red-700 dark:bg-red-500/10 dark:text-red-300"

  defp ok(socket), do: {:ok, socket}
end
