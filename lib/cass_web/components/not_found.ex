defmodule CassWeb.NotFound do
  @moduledoc """
  Renders the public "not found" state used by catalog LiveViews when a
  resource is unknown, unpublished, or otherwise not publicly accessible.
  The page returns HTTP 200 but is marked `noindex` and leaks no data.
  """
  use CassWeb, :html

  attr :resource, :string, default: "page", doc: "the kind of resource that was not found"

  def not_found(assigns) do
    ~H"""
    <div id="not-found" class="flex flex-col items-center justify-center py-20 text-center">
      <span class="grid size-14 place-items-center rounded-2xl bg-zinc-100 dark:bg-white/5">
        <.icon name="hero-magnifying-glass" class="size-7 text-zinc-400" />
      </span>
      <h1 class="mt-6 text-2xl font-semibold tracking-tight text-zinc-900 dark:text-white">
        {@resource} not found
      </h1>
      <p class="mt-2 max-w-sm text-sm leading-6 text-zinc-500 dark:text-zinc-400">
        The resource you are looking for does not exist, is no longer available, or is not
        published yet.
      </p>
      <a
        href={~p"/catalog"}
        class="mt-8 inline-flex items-center gap-2 rounded-xl bg-brand-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-700"
      >
        Browse the catalog <.icon name="hero-arrow-right" class="size-4" />
      </a>
    </div>
    """
  end
end
