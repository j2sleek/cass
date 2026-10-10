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

  ## Ownership and authorization (Milestone 3 Phase 3)

  A product either belongs to the platform (`owner_id == nil`) or to one
  account (`owner_id == <user id>`). Ownership is a *fact about the product*,
  not a capability, and it is fully independent of the `Cass.Accounts` roles
  that grant the capability to act on it:

    * `can_create_owned_product?/1` — the caller is authenticated **and** holds
      `:vendor` or `:admin`. `:admin` grants this independently of `:vendor`.
    * `can_manage_product?/2` — the caller is an `:admin`, or the product's
      `owner_id` is the caller's own user id. A platform-owned product has no
      owner, so only the admin branch can match it.

  Every product mutation takes the caller's `Cass.Accounts.Scope` as its first
  argument and checks `can_manage_product?/2` *before* touching the row, so
  authorization cannot be skipped by a caller that reaches the context
  directly. The refusal is an `{:error, changeset}` on `:base` with a message
  that never distinguishes "not yours" from "does not exist", so a probe cannot
  enumerate products.

  The security property of creation is that **ownership always comes from the
  trusted scope, never from `attrs`**: `owner_id` is absent from
  `Cass.Catalog.Product.changeset/2`'s cast list, and
  `create_owned_product/3` writes `scope.user.id` itself. A submitted
  `owner_id` is therefore not rejected, it is ignored — there is no error to
  teach an attacker what the field is for, and no code path where a request
  names the account a product belongs to.

  Ownership reads are separate from the public reads on purpose:
  `list_managed_products/1` and `get_managed_product/2` scope a query by the
  caller's rights (all products for an admin, only their own otherwise, nothing
  for a guest) and return `nil` rather than a row the caller may not see. The
  unfiltered `get_product!/1` getter that predated ownership has been removed:
  with owner-scoped products in the table it is a guaranteed IDOR footgun, and
  it had no callers.

  `create_product/2` remains the **platform-owned** creation path for trusted
  server callers (seeds, operator tasks) and still leaves `owner_id` unset. It
  is never reachable from a request, and the matching `publish_platform_product/1`
  refuses to publish an owned product, so a server path cannot quietly publish
  somebody else's listing.

  ## Return conventions

  `{:ok, record}` / `{:error, changeset}` / `nil`.
  """
  import Ecto.Query, warn: false

  alias Cass.Accounts.{Scope, User}
  alias Cass.Catalog.{Category, Product, ProductVariant}
  alias Cass.Repo

  @not_authorized_to_create "you are not authorized to create a product"
  @not_authorized_to_manage "you are not authorized to manage this product"

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

  @doc """
  Fetches a category by id, returning `nil` when it does not exist.

  Used where the id arrives from a form (which category should this product be
  filed under?): the id only ever selects a row, and the resolved
  `%Category{}` struct — not the id — is what `create_owned_product/3` is given,
  so a tampered id cannot become a foreign key.
  """
  def get_category(id) when is_integer(id), do: Repo.get(Category, id)

  def get_category(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> get_category(id)
      _not_a_number -> nil
    end
  end

  def get_category(_id), do: nil

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
  def list_public_products, do: list_public_products([])

  @doc """
  Returns publicly discoverable products with optional discovery controls.

  Supported options:

    * `:q` — case-insensitive search across the name, short description,
      and description
    * `:sort` — `:newest` (default), `:price_asc`, `:price_desc`, or `:name`,
      ordering by the lowest active-variant price for the price sorts
    * `:limit` — maximum number of products to return

  Products are always filtered to `:public` visibility via
  `public_product_query/1`, so the search never surfaces drafts, unlisted
  items, or products in inactive categories.
  """
  def list_public_products(opts) when is_list(opts) do
    q = opts[:q]
    sort = normalize_sort_option(opts[:sort] || :newest)
    limit = opts[:limit]

    query =
      Product
      |> public_product_query()
      |> where([p], p.visibility == :public)
      |> filter_products_by_terms(q)
      |> order_public_products(sort)

    query = if limit, do: from(p in query, limit: ^limit), else: query
    Repo.all(query)
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
  Returns the publicly reachable products whose ids are in `ids`.

  The filtering contract mirrors `get_public_product_by_slug/1`: `:published`
  status, publication due, an `:active` category, and `:public` or `:unlisted`
  visibility — so a product that was saved while public keeps appearing even
  if the seller later unlists it, while a draft, archived, or `:private`
  product simply is not in the result. The public query never probes rows it
  would refuse to show; favorites built on this can pin quiet products without
  ever advertising them. Returns `[]` for an empty input, matching the shape
  of the other public reads.
  """
  def list_public_products_by_ids([]), do: []

  def list_public_products_by_ids(ids) when is_list(ids) do
    Product
    |> public_product_query()
    |> where([p], p.visibility in [:public, :unlisted])
    |> where([p], p.id in ^ids)
    |> Repo.all()
  end

  ## Discovery filters
  #
  # These are pure functions over an already-loaded list rather than query
  # options, and that is deliberate. `public_product_query/1` preloads
  # `active_variants` on every row — variants are the authority on both price
  # and stock, and the storefront renders that exact list — so filtering in
  # memory costs no additional query and cannot disagree with what the page
  # shows. Keeping them as ordinary functions also means a LiveView can derive
  # facet counts from the same list it is about to render, so a facet count and
  # the filtered result set can never come from two different queries.

  @doc """
  Keeps only the products whose `product_type` is one of `types`.

  `types` is a list of atoms from the closed vocabulary (`product_types/0`);
  anything outside it is ignored rather than raising, so URL-derived input can
  never widen what the query means. An empty list is the "no type filter" case
  and returns the input unchanged, in its original order, so a sort applied by
  the caller survives.
  """
  def filter_by_product_types(products, types) when is_list(products) and is_list(types) do
    case Enum.filter(product_types(), &(&1 in types)) do
      [] -> products
      allowed -> Enum.filter(products, &(&1.product_type in allowed))
    end
  end

  @doc """
  Keeps the products whose lowest active-variant price falls inside the
  `min_price_cents`..`max_price_cents` band. Either bound may be `nil`.

  The bound is the same "From $X" price a card shows and the same value the
  price sorts order by, so a product filtered into the band is always displayed
  at a price the buyer was shown. A product with no active variant has no price
  and therefore cannot sit in a band, so an active band excludes it.
  """
  def filter_by_price_band(products, nil, nil), do: products

  def filter_by_price_band(products, min_price_cents, max_price_cents)
      when is_list(products) do
    Enum.filter(products, fn product ->
      case lowest_price_cents(product) do
        nil -> false
        price -> within_band?(price, min_price_cents, max_price_cents)
      end
    end)
  end

  @doc """
  Keeps only the products that can be bought right now: at least one active
  variant that is not sold out. A `nil` stock is unlimited supply, matching
  `Cass.Catalog.ProductVariant.purchasable?/1`.

  `false` (the default browsing state) is a no-op.
  """
  def filter_by_stock(products, false), do: products

  def filter_by_stock(products, true) when is_list(products),
    do: Enum.filter(products, &in_stock?/1)

  @doc """
  Returns the lowest price across a product's active variants in integer cents,
  or `nil` when it has no active variant (a product nobody can buy yet, which is
  why the card renders no price for it).
  """
  def lowest_price_cents(%{active_variants: variants}) when is_list(variants) do
    case Enum.map(variants, & &1.price_cents) do
      [] -> nil
      prices -> Enum.min(prices)
    end
  end

  def lowest_price_cents(_product), do: nil

  @doc """
  Returns true when the product has an active variant that is not sold out —
  the storefront's "available now" test.
  """
  def in_stock?(%{active_variants: variants}) when is_list(variants) do
    Enum.any?(variants, fn variant -> is_nil(variant.stock) or variant.stock > 0 end)
  end

  def in_stock?(_product), do: false

  @doc """
  Returns a facet map: every type in the closed vocabulary mapped to how many of
  `products` carry it, zeros included.

  Pass the list filtered by everything *except* the type facet — that is what
  makes each count answer "how many would I get if I picked this type?" while
  every other active filter stays applied.
  """
  def product_type_counts(products) when is_list(products) do
    counts = Enum.frequencies_by(products, & &1.product_type)

    Map.new(product_types(), fn type -> {type, Map.get(counts, type, 0)} end)
  end

  defp within_band?(price, min_price_cents, max_price_cents) do
    (is_nil(min_price_cents) or price >= min_price_cents) and
      (is_nil(max_price_cents) or price <= max_price_cents)
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

  @doc """
  Creates a platform-owned product that belongs to the given category.

  This is the trusted server path used by `priv/repo/seeds.exs` and operator
  tasks: it sets no owner, leaving `owner_id` as `nil`, and it is not reachable
  from a request. Use `create_owned_product/3` for anything driven by a signed-in
  user.
  """
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
  Creates a product owned by the signed-in user of `scope`.

  The owner is `scope.user.id` and nothing else: `:owner_id` is never cast, so
  an `owner_id` in `attrs` is ignored rather than obeyed, and there is no way to
  create a product owned by another account. `:vendor` and `:admin` are both
  accepted, independently of each other; every other caller (an ordinary
  customer, or a guest) is refused.
  """
  def create_owned_product(%Scope{} = scope, %Category{} = category, attrs) do
    cond do
      not can_create_owned_product?(scope) ->
        not_authorized(%Product{}, @not_authorized_to_create)

      category.status == :archived ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(%Product{}),
           :category_id,
           "cannot add products to an archived category"
         )}

      true ->
        owned_product_changeset(scope, category, attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Builds (and validates) the changeset for the `create_owned_product/3` form
  without inserting anything, so a form can show errors as it is typed.
  """
  def change_owned_product(%Scope{} = scope, %Category{} = category, attrs) do
    if can_create_owned_product?(scope) do
      {:ok, owned_product_changeset(scope, category, attrs)}
    else
      not_authorized(%Product{}, @not_authorized_to_create)
    end
  end

  @doc """
  Builds (and validates) the changeset for the `update_product/3` form, refusing
  outright when the caller may not manage the product.
  """
  def change_product(%Scope{} = scope, %Product{} = product, attrs) do
    if can_manage_product?(scope, product) do
      {:ok, Product.update_changeset(product, attrs)}
    else
      not_authorized(product, @not_authorized_to_manage)
    end
  end

  @doc """
  Updates a product.

  The caller must be allowed to manage the product (see `can_manage_product?/2`),
  which is checked before the row is touched. Rejects updates to archived
  products and any slug change once the product is published, exactly as before
  ownership existed.
  """
  def update_product(%Scope{} = scope, %Product{} = product, attrs) do
    if can_manage_product?(scope, product) do
      product
      |> Product.update_changeset(attrs)
      |> Repo.update()
    else
      not_authorized(product, @not_authorized_to_manage)
    end
  end

  @doc """
  Transitions a product from `:draft` to `:published`, stamping `published_at`
  with the current time.

  The caller must be allowed to manage the product, which matters most here:
  publishing is what makes a seller's draft publicly visible. Rejects publishing
  when the product is not a draft or when its category is archived.
  """
  def publish_product(%Scope{} = scope, %Product{} = product) do
    if can_manage_product?(scope, product) do
      do_publish_product(product)
    else
      not_authorized(product, @not_authorized_to_manage)
    end
  end

  @doc """
  Publishes a **platform-owned** product from a trusted server path.

  `create_product/2` has no scope to authorize against, so the seeds and
  operator tasks that use it need a matching way to publish what they created.
  It refuses a product that has an owner, which keeps the rule one-directional:
  a server path can publish the platform's own products, and an owned product
  can only be published by its owner or an admin through `publish_product/2`.
  """
  def publish_platform_product(%Product{} = product) do
    if Product.platform_owned?(product) do
      do_publish_product(product)
    else
      not_authorized(
        product,
        "only a platform-owned product can be published without a scope"
      )
    end
  end

  @doc "Archives a product, removing it from all public queries. Immutable afterwards."
  def archive_product(%Scope{} = scope, %Product{} = product) do
    cond do
      not can_manage_product?(scope, product) ->
        not_authorized(product, @not_authorized_to_manage)

      product.status == :archived ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(product),
           :base,
           "product is already archived"
         )}

      true ->
        product
        |> Ecto.Changeset.change(status: :archived)
        |> Repo.update()
    end
  end

  ## Product types

  @doc "Returns the closed vocabulary of product types."
  def product_types, do: Ecto.Enum.values(Product, :product_type)

  @doc """
  Returns the `product_type` of the product that owns `variant_id`.

  A deliberately narrow projection: the Fulfillment boundary needs to know *what
  kind of thing* was purchased (to pick a delivery mechanism via
  `Cass.Fulfillment.kind_for/1`) and nothing else about the catalog row, so this
  returns a single atom rather than a `%Product{}`. Returning the product struct
  instead would hand the fulfillment boundary a full catalog read it has no
  business performing, and re-introduce the unfiltered `get_product!/1` fetch
  that ownership removed on purpose.

  Returns `{:ok, product_type}` or `{:error, :unknown_variant}`. The lookup is
  safe to rely on for a historical purchase: `cass_product_variants.product_id`
  and `cass_order_items.product_variant_id` are both `on_delete: :restrict`, so a
  purchased variant's product can never disappear, and the fulfillment and
  entitlement rows snapshot the resolved type when they are created.
  """
  def get_product_type_for_variant(variant_id) when is_integer(variant_id) do
    case Repo.one(
           from v in ProductVariant,
             join: p in assoc(v, :product),
             where: v.id == ^variant_id,
             select: p.product_type
         ) do
      nil -> {:error, :unknown_variant}
      product_type -> {:ok, product_type}
    end
  end

  def get_product_type_for_variant(_variant_id), do: {:error, :unknown_variant}

  ## Product variants

  @doc """
  Returns every variant of a product for a caller that may manage it, ordered
  by `sort_order` then id.

  A caller that may not manage the product gets `[]` — the same
  non-enumerable shape as `list_managed_products/1`. The product row itself is
  never the input here; callers reach variants through a product they already
  hold.
  """
  def list_product_variants(%Scope{} = scope, %Product{} = product) do
    if can_manage_product?(scope, product) do
      list_variants_by_query(variant_query(product, []))
    else
      []
    end
  end

  @doc """
  Returns the active variants of a product, ordered by `sort_order` then id.

  This is the **purchasable** read: the future checkout boundary must pick
  variants from here (or apply `ProductVariant.purchasable?/1` to a row it
  already holds), so an inactive variant can never be bought. Nothing in this
  function is gated on authorization because nothing here is secret once the
  product itself is public.
  """
  def list_active_variants(%Product{} = product) do
    list_variants_by_query(variant_query(product, [:active]))
  end

  @doc """
  Creates a variant for `product` on behalf of `scope`.

  Mirrors `create_product/3`'s security shape: the caller must be able to
  manage the product, `product_id` is written from the resolved `%Product{}`
  rather than read from `attrs`, and a refusal is a non-enumerable changeset
  error. Ownership is inherited from the product — a vendor can only add
  variants to its own products.
  """
  def create_variant(%Scope{} = scope, %Product{} = product, attrs) do
    if can_manage_product?(scope, product) do
      %ProductVariant{}
      |> ProductVariant.changeset(attrs)
      |> Ecto.Changeset.put_change(:product_id, product.id)
      |> Repo.insert()
    else
      not_authorized(%ProductVariant{}, @not_authorized_to_manage)
    end
  end

  @doc """
  Builds (and validates) the changeset for the variant form without inserting,
  refusing outright when the caller may not manage the product.
  """
  def change_variant(%Scope{} = scope, %Product{} = product, attrs) do
    if can_manage_product?(scope, product) do
      {:ok,
       %ProductVariant{}
       |> ProductVariant.changeset(attrs)
       |> Ecto.Changeset.put_change(:product_id, product.id)}
    else
      not_authorized(%ProductVariant{}, @not_authorized_to_manage)
    end
  end

  @doc """
  Updates a variant, refusing when the caller may not manage the variant's
  product.
  """
  def update_variant(%Scope{} = scope, %ProductVariant{} = variant, attrs) do
    variant = Repo.preload(variant, :product)

    if can_manage_product?(scope, variant.product) do
      variant
      |> ProductVariant.changeset(attrs)
      |> Repo.update()
    else
      not_authorized(variant, @not_authorized_to_manage)
    end
  end

  ## Authorization

  @doc """
  Returns true when `scope` may create a product it owns.

  That requires an authenticated scope holding `:vendor` or `:admin`. An admin
  qualifies on its own: `:admin` grants the capability independently of
  `:vendor`, and a plain customer or a guest never does.
  """
  def can_create_owned_product?(%Scope{} = scope) do
    Scope.authenticated?(scope) and (Scope.admin?(scope) or Scope.vendor?(scope))
  end

  def can_create_owned_product?(_scope), do: false

  @doc """
  Returns true when `scope` may update, publish, or archive `product`.

  An `:admin` may manage any product, including a platform-owned one. Everyone
  else may only manage a product whose `owner_id` is their own user id, which
  makes a platform-owned product (`owner_id == nil`) admin-only: the owner
  comparison can never match `nil`, and a guest has no user id to match either.

  Because only `:vendor` and `:admin` can create an owned product, the owner
  branch can only ever be reached by an account that held one of those roles;
  an ordinary customer owns nothing and therefore manages nothing. Note that
  the owner branch deliberately does not re-check the caller's roles, so revoking
  `:vendor` stops new products from being created without orphaning the
  products that already exist. Reassigning them is a transfer feature, which
  this phase does not implement.
  """
  def can_manage_product?(%Scope{} = scope, %Product{} = product) do
    Scope.admin?(scope) or
      (Scope.authenticated?(scope) and product.owner_id == scope.user.id)
  end

  def can_manage_product?(_scope, _product), do: false

  @doc """
  Returns true when `user` owns at least one product, in any status.

  This is the precondition `Cass.Accounts.delete_user/1` checks before
  deactivating an account. A catalog is a seller's published work and must not be
  silently orphaned, which is exactly why `cass_products.owner_id` is
  `on_delete: :restrict`; because account deletion is a soft delete the foreign
  key is never exercised, so the check has to be explicit here.

  Archived and draft products count: ownership does not end when a product stops
  being served. A non-user (or an unsaved one) owns nothing.
  """
  @spec owns_any_product?(User.t() | term()) :: boolean()
  def owns_any_product?(%User{id: owner_id}) when is_integer(owner_id) do
    Repo.exists?(from p in Product, where: p.owner_id == ^owner_id)
  end

  def owns_any_product?(_user), do: false

  @doc """
  Returns the products `scope` is allowed to manage: every product for an admin,
  only the caller's own products for everybody else, and nothing for a guest.
  """
  def list_managed_products(%Scope{} = scope) do
    case manageable_products_query(scope) do
      nil -> []
      query -> Repo.all(query)
    end
  end

  def list_managed_products(_scope), do: []

  @doc """
  Fetches a product by id **only if** `scope` may manage it, returning `nil`
  otherwise.

  A missing product and a product belonging to somebody else are deliberately
  indistinguishable: both are `nil`. This is the query the management surface
  uses instead of a bare primary-key fetch, so knowing another seller's product
  id, slug, or URL is not enough to load it.
  """
  def get_managed_product(%Scope{} = scope, product_id) when is_integer(product_id) do
    case manageable_products_query(scope) do
      nil ->
        nil

      query ->
        case Repo.one(from p in query, where: p.id == ^product_id) do
          nil -> nil
          product -> preload_management(product)
        end
    end
  end

  def get_managed_product(%Scope{} = scope, product_id) when is_binary(product_id) do
    case Integer.parse(product_id) do
      {product_id, ""} -> get_managed_product(scope, product_id)
      _not_a_number -> nil
    end
  end

  def get_managed_product(_scope, _product_id), do: nil

  ## Shared internals
  defp owned_product_changeset(%Scope{} = scope, %Category{} = category, attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Ecto.Changeset.put_change(:category_id, category.id)
    |> Ecto.Changeset.put_change(:owner_id, scope.user.id)
  end

  defp do_publish_product(%Product{} = product) do
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

  # The single shape of an authorization failure. Returning it as a changeset
  # error (rather than raising or returning a distinct not-found) keeps the
  # refusal non-enumerable and lets a form render it like any other error.
  defp not_authorized(struct, message) do
    {:error, Ecto.Changeset.add_error(Ecto.Changeset.change(struct), :base, message)}
  end

  defp managed_products_query do
    from p in Product, order_by: [asc: p.name, asc: p.id], preload: [:category, :owner]
  end

  # The ownership filter is part of the query rather than a check applied to a
  # fetched row, so "manageable" is expressed exactly once and a row the caller
  # may not see is never loaded in the first place. Returns `nil` when nothing
  # can match, which is the case for a guest.
  defp manageable_products_query(%Scope{} = scope) do
    cond do
      Scope.admin?(scope) ->
        managed_products_query()

      Scope.authenticated?(scope) ->
        where(managed_products_query(), [p], p.owner_id == ^scope.user.id)

      true ->
        nil
    end
  end

  defp variant_query(%Product{} = product, filters) do
    base =
      from v in ProductVariant,
        where: v.product_id == ^product.id,
        order_by: [asc: v.sort_order, asc: v.id]

    if :active in filters, do: where(base, [v], v.active == true), else: base
  end

  defp list_variants_by_query(query), do: Repo.all(query)

  defp preload_management(%Product{} = product), do: Repo.preload(product, [:category, :owner])

  defp public_variant_query do
    from v in ProductVariant, where: v.active == true, order_by: [asc: v.sort_order, asc: v.id]
  end

  defp public_product_query(query) do
    now = utc_now()

    from p in query,
      join: c in assoc(p, :category),
      where: c.status == :active,
      where: p.status == :published,
      where: is_nil(p.published_at) or p.published_at <= ^now,
      preload: [
        owner: :vendor_profile,
        category: c,
        active_variants: ^public_variant_query()
      ]
  end

  defp filter_products_by_terms(query, q) when is_binary(q) do
    q = String.trim(q)

    if q == "" do
      query
    else
      pattern = "%#{q}%"

      from p in query,
        where:
          ilike(p.name, ^pattern) or
            ilike(fragment("coalesce(?, '')", p.short_description), ^pattern) or
            ilike(fragment("coalesce(?, '')", p.description), ^pattern)
    end
  end

  defp filter_products_by_terms(query, _q), do: query

  defp normalize_sort_option(sort) when sort in ["name", :name], do: :name
  defp normalize_sort_option(sort) when sort in ["price_asc", :price_asc], do: :price_asc
  defp normalize_sort_option(sort) when sort in ["price_desc", :price_desc], do: :price_desc
  defp normalize_sort_option(_other), do: :newest

  defp order_public_products(query, :name), do: from(p in query, order_by: [asc: p.name])

  defp order_public_products(query, :price_asc) do
    from p in query,
      left_join: sub in subquery(min_price_subquery()),
      on: sub.product_id == p.id,
      order_by: [asc_nulls_last: sub.min_price]
  end

  defp order_public_products(query, :price_desc) do
    from p in query,
      left_join: sub in subquery(min_price_subquery()),
      on: sub.product_id == p.id,
      order_by: [desc_nulls_last: sub.min_price]
  end

  defp order_public_products(query, _sort) do
    from p in query, order_by: [desc: p.published_at]
  end

  defp min_price_subquery do
    from v in ProductVariant,
      where: v.active == true,
      group_by: v.product_id,
      select: %{product_id: v.product_id, min_price: min(v.price_cents)}
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
