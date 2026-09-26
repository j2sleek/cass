defmodule Cass.Catalog.Category do
  @moduledoc """
  A grouping of products within the marketplace catalog.

  Categories form a single-level hierarchy: each category may optionally belong
  to a parent category. Root categories have `parent_id` set to `nil`.

  Statuses:

    * `:active` — visible in public catalog navigation and listings.
    * `:archived` — excluded from all public queries. Archiving does **not**
      cascade to children or products; it relies on the public query rules
      (`category.status == :active`) to hide the subtree from listings.

  Slugs are globally unique and immutable once a category is archived.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Catalog.{Category, Product}

  schema "cass_categories" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :seo_title, :string
    field :seo_description, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active

    belongs_to :parent, Category, foreign_key: :parent_id
    has_many :children, Category, foreign_key: :parent_id
    has_many :products, Product, foreign_key: :category_id

    timestamps(type: :utc_datetime)
  end

  @slug_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc false
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :slug, :description, :seo_title, :seo_description])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_length(:slug, min: 2, max: 100)
    |> validate_format(:slug, @slug_regex,
      message: "must be lowercase letters, numbers, and single hyphens"
    )
    |> validate_length(:description, max: 2000)
    |> validate_seo()
    |> unique_constraint(:slug)
    |> unique_constraint(:name, name: :cass_categories_root_name_index)
    |> unique_constraint(:name, name: :cass_categories_sibling_name_index)
  end

  @doc false
  def update_changeset(category, attrs) do
    category
    |> changeset(attrs)
    |> validate_modifiable(category)
  end

  defp validate_seo(changeset) do
    changeset
    |> validate_length(:seo_title, max: 60)
    |> validate_length(:seo_description, max: 160)
  end

  defp validate_modifiable(changeset, %{status: :archived}) do
    add_error(changeset, :base, "archived categories cannot be modified")
  end

  defp validate_modifiable(changeset, %{status: _}), do: changeset
end
