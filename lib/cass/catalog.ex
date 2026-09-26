defmodule Cass.Catalog do
  @moduledoc """
  The Catalog context manages categories and products.

  ## Design decisions

  * **Slug uniqueness** — category and product slugs are globally unique in
    `cass_categories` / `cass_products` (enforced by unique indexes cleaned to
    lowercase). This keeps public URLs short and simple
    (`/catalog/categories/:slug`, `/catalog/products/:slug`).
  * **Category names** — unique among siblings, case-insensitively, enforced
    by partial unique indexes (roots vs. children are indexed separately).
  * **Product names** — not unique; the slug is the identity key.
  * **Products always belong to a category** (`category_id` is required). FK
    ids are never cast from params; they are set programmatically here.
  * **Immutable slugs** — a product slug is frozen once published or archived;
    an archived category is fully immutable.
  * **Archiving is not cascading** — archiving a category leaves children and
    products untouched. Public rules filter on `category.status == :active`, so
    an archived category (and anything only reachable through it) drops out of
    listings automatically. A child category of an archived root is still
    reachable by direct URL at this milestone; enforcing a full-active-ancestor
    rule would require a closure table or recursive query and is deferred.
  * **`published_at`** — set when a draft transitions to `published`. A product
    is publicly due only once `published_at <= now` (nil means immediately due).
  * **`canonical_url`** — stored, optional, reserved for future external
    canonicalization; public pages currently derive the canonical URL from the
    storefront endpoint.
  * **Public query contract** — the `list_public_*`/`get_public_*` functions
    are the only entry points for the web layer and never expose drafts,
    archived items, `:private` products, or products in non-`:active` categories.

  Return conventions: `{:ok, record}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Catalog.{Category, Product}
  alias Cass.Repo

  @doc "Returns all categories (any status), ordered by name."
  def list_categories do
    Repo.all(from c in Category, order_by: c.name)
  end

  @doc """
  Returns publicly navigable root categories (status `:active`), each with its
  `:active` direct children preloaded.
  """
  def list_public_categories do
    children_query = from(child in Category, where: child.status == :active, order_by: child.name)

    Repo.all(
      from c in Category,
        where: c.status == :active and is_nil(c.parent_id),
        order_by: c.name,
        preload: [children: ^children_query]
    )
  end

  @doc "Returns the public (active) child categories of the given category."
  def list_child_categories(%Category{} = category), do: list_child_categories(category.id)

  def list_child_categories(category_id) do
    Repo.all(
      from c in Category,
        where: c.parent_id == ^category_id and c.status == :active,
        order_by: c.name
    )
  end

  @doc "Fetches a category by id, raising if it does not exist."
  def get_category!(id), do: Repo.get!(Category, id)

  @doc "Fetches a category by slug regardless of status."
  def get_category_by_slug(slug), do: Repo.get_by(Category, slug: slug)

  @doc """
  Fetches a publicly navigable category by slug (status `:active`), with its
  `:active` children and parent chain preloaded. Returns `nil` when the slug is
  unknown or the category is not active.
  """
  def get_public_category_by_slug(slug) do
    children_query = from(child in Category, where: child.status == :active, order_by: child.name)

    Repo.one(
      from c in Category,
        where: c.slug == ^slug and c.status == :active,
        preload: [children: ^children_query, parent: :parent]
    )
  end

  @doc "Creates a root category from `attrs`."
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Creates a category that belongs to the given parent."
  def create_child_category(%Category{status: :archived}, _attrs) do
    {:error,
     Ecto.Changeset.add_error(
       Ecto.Changeset.change(%Category{}),
       :base,
       "cannot add categories under an archived category"
     )}
  end

  def create_child_category(%Category{} = parent, attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> Ecto.Changeset.put_change(:parent_id, parent.id)
    |> Repo.insert()
  end

  @doc "Updates a category, rejecting changes to archived categories."
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Archives a category. Children and products are left intact; they simply stop
  being surfaced by the public query rules.
  """
  def archive_category(%Category{status: :archived} = category) do
    {:error,
     Ecto.Changeset.add_error(
       Ecto.Changeset.change(category),
       :base,
       "category is already archived"
     )}
  end

  def archive_category(%Category{} = category) do
    category
    |> Ecto.Changeset.change(status: :archived)
    |> Repo.update()
  end

  @doc """
  Returns all publicly discoverable products: status `:published`, visibility
  `:public`, due for publication, and belonging to an `:active` category.
  """
  def list_public_products do
    Product
    |> public_product_query()
    |> where([p], p.visibility == :public)
    |> order_by([p], desc: p.published_at)
    |> Repo.all()
  end

  @doc "Returns the publicly discoverable products directly inside a category."
  def list_public_products_by_category(%Category{} = category) do
    Product
    |> public_product_query()
    |> where([p], p.category_id == ^category.id)
    |> where([p], p.visibility == :public)
    |> order_by([p], desc: p.published_at)
    |> Repo.all()
  end

  @doc """
  Fetches a product by slug for the public web layer. Allows `:public` and
  `:unlisted` visibility (listings exclude `:unlisted`); returns `nil` for
  drafts, archived items, `:private` products, products in non-`:active`
  categories, and unknown slugs.
  """
  def get_public_product_by_slug(slug) do
    Product
    |> public_product_query()
    |> where([p], p.slug == ^slug)
    |> where([p], p.visibility in [:public, :unlisted])
    |> Repo.one()
  end

  @doc "Fetches a product by id, raising if it does not exist."
  def get_product!(id), do: Repo.get!(Product, id)

  @doc "Creates a product that belongs to the given category."
  def create_product(%Category{status: :archived}, _attrs) do
    {:error,
     Ecto.Changeset.add_error(
       Ecto.Changeset.change(%Product{}),
       :category_id,
       "cannot add products to an archived category"
     )}
  end

  def create_product(%Category{} = category, attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Ecto.Changeset.put_change(:category_id, category.id)
    |> Repo.insert()
  end

  @doc """
  Updates a product. Rejects updates to archived products and any slug change
  once the product is published.
  """
  def update_product(%Product{} = product, attrs) do
    product
    |> Product.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Transitions a product from `:draft` to `:published`, stamping `published_at`
  with the current time. Rejects publishing when the product is not a draft or
  when its category is archived.
  """
  def publish_product(%Product{} = product) do
    product = Repo.preload(product, :category)

    cond do
      product.status != :draft ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(product),
           :status,
           "only draft products can be published"
         )}

      match?(%Category{status: :archived}, product.category) ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(product),
           :category_id,
           "cannot publish products in an archived category"
         )}

      true ->
        product
        |> Ecto.Changeset.change(status: :published, published_at: utc_now())
        |> Repo.update()
    end
  end

  @doc "Archives a product, removing it from all public queries. Immutable afterwards."
  def archive_product(%Product{status: :archived} = product) do
    {:error,
     Ecto.Changeset.add_error(
       Ecto.Changeset.change(product),
       :base,
       "product is already archived"
     )}
  end

  def archive_product(%Product{} = product) do
    product
    |> Ecto.Changeset.change(status: :archived)
    |> Repo.update()
  end

  defp public_product_query(query) do
    now = utc_now()

    from p in query,
      join: c in assoc(p, :category),
      where: c.status == :active,
      where: p.status == :published,
      where: is_nil(p.published_at) or p.published_at <= ^now,
      preload: [category: c]
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
