# Seeds the dev database with the public storefront foundation: the three root
# catalog categories and one published public product per category.
#
#     mix run priv/repo/seeds.exs
alias Cass.Catalog

defmodule Cass.Seeds.CatalogSeeder do
  alias Cass.Catalog

  @catalog [
    %{
      name: "Digital Products",
      slug: "digital-products",
      description:
        "Downloadable software, templates, presets, and tools delivered instantly after purchase.",
      products: [
        %{
          name: "Projects Dashboard Kit",
          slug: "projects-dashboard-kit",
          product_type: :digital_product,
          visibility: :public,
          short_description:
            "A reusable Elixir + Phoenix dashboard starter with roles, audits, and charts.",
          description:
            "A batteries-included dashboard starter for Elixir teams. Ships with a role-based\naccess system, an audited admin area, and dependency-aware chart components."
        }
      ]
    },
    %{
      name: "Social Marketing Services",
      slug: "social-marketing-services",
      description:
        "Compliant, provider-less social media growth and engagement handled by real humans.",
      products: [
        %{
          name: "Content Calendars, Done For You",
          slug: "content-calendars-done-for-you",
          product_type: :smm_service,
          visibility: :public,
          short_description:
            "A 30-day, platform-tailored posting calendar reviewed by a human strategist.",
          description:
            "We pair you with a human strategist who builds a 30-day calendar tailored to your\nbrand voice. Includes platform-tailored posting times and a compliance review."
        }
      ]
    },
    %{
      name: "AI Tools",
      slug: "ai-tools",
      description:
        "Curated AI-powered tools verified to keep your data private and your output compliant.",
      products: [
        %{
          name: "Email Tone Adjuster",
          slug: "email-tone-adjuster",
          product_type: :ai_tool,
          visibility: :public,
          short_description:
            "Rewrite any draft email at five tone levels without ever sharing your account.",
          description:
            "A privacy-first tool that rewrites drafts to friendly, formal, confident, concise, or\npersuasive tones. Your messages are processed in-session and never stored."
        }
      ]
    }
  ]

  def run do
    Enum.each(@catalog, &seed_root/1)
    IO.puts("Catalog seed complete.")
  end

  defp seed_root(%{products: products} = category) do
    root =
      case Catalog.get_category_by_slug(category.slug) do
        nil ->
          {:ok, root} = Catalog.create_category(Map.delete(category, :products))
          IO.puts("  seeded category: #{root.name}")
          root

        existing ->
          IO.puts("  category exists: #{existing.name}")
          existing
      end

    Enum.each(products, &seed_product(root, &1))
  end

  defp seed_product(category, attrs) do
    case Catalog.get_public_product_by_slug(attrs.slug) do
      nil ->
        {:ok, product} = Catalog.create_product(category, attrs)
        {:ok, published} = Catalog.publish_product(product)
        IO.puts("  seeded product: #{published.name}")

      _ ->
        IO.puts("  product exists: #{attrs.slug}")
    end
  end
end

Cass.Seeds.CatalogSeeder.run()
