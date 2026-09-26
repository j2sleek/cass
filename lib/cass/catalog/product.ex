defmodule Cass.Catalog.Product do
  @moduledoc """
  An item offered in the marketplace catalog.

  A product always belongs to a category and represents one of three product
  types: `digital_product`, `smm_service`, or `ai_tool`.

  Lifecycle (`status`):

    * `:draft` — can be edited freely; never served publicly.
    * `:published` — served publicly when `visibility` is `:public` or
      `:unlisted` and `published_at` has been reached. The slug is frozen.
    * `:archived` — excluded from all public queries and immutable.

  Visibility:

    * `:public` — discoverable in listings and directly accessible.
    * `:unlisted` — accessible by direct slug but excluded from listings and
      marked `noindex` on the public page.
    * `:private` — never accessible through any public route.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Catalog.Category

  schema "cass_products" do
    field :name, :string
    field :slug, :string
    field :product_type, Ecto.Enum, values: [:digital_product, :smm_service, :ai_tool]
    field :status, Ecto.Enum, values: [:draft, :published, :archived], default: :draft
    field :visibility, Ecto.Enum, values: [:public, :unlisted, :private], default: :private
    field :short_description, :string
    field :description, :string
    field :seo_title, :string
    field :seo_description, :string
    field :canonical_url, :string
    field :published_at, :utc_datetime

    belongs_to :category, Category, foreign_key: :category_id

    timestamps(type: :utc_datetime)
  end

  @slug_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc false
  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :name,
      :slug,
      :product_type,
      :visibility,
      :short_description,
      :description,
      :seo_title,
      :seo_description,
      :canonical_url
    ])
    |> validate_required([:name, :slug, :product_type])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:slug, min: 2, max: 120)
    |> validate_format(:slug, @slug_regex,
      message: "must be lowercase letters, numbers, and single hyphens"
    )
    |> validate_length(:short_description, max: 200)
    |> validate_length(:description, max: 4000)
    |> validate_canonical_url()
    |> unique_constraint(:slug)
  end

  @doc false
  def update_changeset(product, attrs) do
    product
    |> changeset(attrs)
    |> validate_modifiable(product)
    |> validate_slug_immutable(product)
  end

  defp validate_canonical_url(changeset) do
    case get_change(changeset, :canonical_url) do
      nil ->
        changeset

      url ->
        if Regex.match?(~r/\Ahttps?:\/\//i, url) and match?({:ok, _}, URI.new(url)) do
          changeset
        else
          add_error(changeset, :canonical_url, "must be an absolute http(s) URL")
        end
    end
  end

  defp validate_modifiable(changeset, %{status: :archived}) do
    add_error(changeset, :base, "archived products cannot be modified")
  end

  defp validate_modifiable(changeset, %{status: _}), do: changeset

  defp validate_slug_immutable(changeset, %{status: status})
       when status in [:published, :archived] do
    if get_change(changeset, :slug) do
      add_error(changeset, :slug, "cannot be changed once the product is published")
    else
      changeset
    end
  end

  defp validate_slug_immutable(changeset, %{status: _}), do: changeset
end
