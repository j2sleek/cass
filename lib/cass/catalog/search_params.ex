defmodule Cass.Catalog.SearchParams do
  @moduledoc """
  Search, filter, sort and pagination options for the public catalog index.

  This is a plain struct rather than a changeset: nothing here is ever written
  back, and every field is read from the query string by the catalog LiveView.

  Defaults are chosen so that a bare `/catalog` visit is identical in ordering
  to `Cass.Catalog.list_public_products/0` — newest first, first page.

  Every field is untrusted input. `Cass.Catalog.search_public_products/1`
  normalises the whole struct before it reaches the database, so a struct built
  from raw params can never widen what is publicly visible.
  """

  # String literals are not expressible as a typespec union, so the allow-list
  # in `sorts/0` is the source of truth and this type stays a string.
  @type sort :: String.t()

  @type t :: %__MODULE__{
          query: String.t() | nil,
          product_type: atom() | nil,
          category_slug: String.t() | nil,
          sort: sort(),
          page: pos_integer(),
          per_page: pos_integer()
        }

  @sorts ~w(newest featured name_asc name_desc price_asc price_desc)
  @per_page_bounds {1, 48}
  @max_term_length 120
  @max_page 100_000

  defstruct query: nil,
            product_type: nil,
            category_slug: nil,
            sort: "newest",
            page: 1,
            per_page: 24

  @doc "The sort keys the catalog accepts, in menu order."
  def sorts, do: @sorts

  @doc "Inclusive `{min, max}` bounds a caller may request for page size."
  def per_page_bounds, do: @per_page_bounds

  @doc """
  Builds a validated struct from raw params.

  This is the only place raw query-string values are turned into this struct,
  so `:sort` is checked against the allow-list, `:page` and `:per_page` are
  clamped into range, and `:query` is trimmed and length-capped. Values that do
  not fit fall back to the documented default rather than raising.
  """
  @spec from_params(map() | keyword()) :: t()
  def from_params(params) when is_list(params), do: from_params(Map.new(params))

  def from_params(params) when is_map(params) do
    product_type = params[:product_type] || params["product_type"]
    category_slug = params[:category_slug] || params["category_slug"]
    sort = params[:sort] || params["sort"]

    {min_page, max_page} = @per_page_bounds

    page = params[:page] || params["page"] || min_page
    per_page = params[:per_page] || params["per_page"] || 24

    %__MODULE__{
      query: normalize_term(params[:query] || params["query"]),
      product_type: product_type,
      category_slug: normalize_slug(category_slug),
      sort: if(is_binary(sort) and sort in @sorts, do: sort, else: "newest"),
      page: clamp_integer(page, min_page, @max_page),
      per_page: clamp_integer(per_page, min_page, max_page)
    }
  end

  def from_params(_params), do: %__MODULE__{}

  @doc "Human label for a sort key, for the visible sort menu."
  def sort_label("newest"), do: "Newest first"
  def sort_label("featured"), do: "Featured"
  def sort_label("name_asc"), do: "Name A–Z"
  def sort_label("name_desc"), do: "Name Z–A"
  def sort_label("price_asc"), do: "Price: low to high"
  def sort_label("price_desc"), do: "Price: high to low"
  def sort_label(_other), do: "Newest first"

  @doc "True when any narrowing option is active, so the UI can offer a reset."
  def active?(%__MODULE__{query: nil, product_type: nil, category_slug: nil}), do: false
  def active?(%__MODULE__{}), do: true

  defp clamp_integer(value, min_page, max_page) when is_integer(value),
    do: value |> max(min_page) |> min(max_page)

  # `?page=2` and `?page=two` are both invalid rather than a 500.
  defp clamp_integer(value, min_page, max_page) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> clamp_integer(parsed, min_page, max_page)
      _ -> min_page
    end
  end

  defp clamp_integer(_value, min_page, _max_page), do: min_page

  defp normalize_term(term) when is_binary(term) do
    case String.trim(term) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_term_length)
    end
  end

  defp normalize_term(_term), do: nil

  defp normalize_slug(slug) when is_binary(slug) do
    case String.trim(slug) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 120)
    end
  end

  defp normalize_slug(_slug), do: nil
end
