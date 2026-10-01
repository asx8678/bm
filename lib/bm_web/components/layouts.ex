defmodule BmWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BmWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  BM's app shell: a slim header (brand, navigation, theme toggle) above the page.

  `full` gives the page the whole remaining height without scrolling the window (for pages that
  manage their own scrolling, like the chat).

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the current section: :chat or :runs"
  attr :full, :boolean, default: false, doc: "fill the viewport height (no window scrolling)"

  slot :inner_block, required: true
  slot :status, doc: "shown at the right of the header"

  def app(assigns) do
    ~H"""
    <div class={["flex flex-col", if(@full, do: "h-dvh", else: "min-h-dvh")]}>
      <header class="sticky top-0 z-20 flex h-11 flex-none items-center gap-4 border-b border-bm-line bg-bm-surface/95 px-4 backdrop-blur">
        <.link
          navigate={~p"/"}
          id="brand"
          class="flex items-baseline gap-2 rounded-md focus-visible:outline-2 focus-visible:outline-bm-text"
        >
          <span class="text-sm font-bold tracking-wide">BM</span>
          <span class="hidden text-[11px] text-bm-muted sm:inline">guarded coding runs</span>
        </.link>
        <%!-- One screen (plan 35): the chat is home; runs pages show the way back. --%>
        <nav :if={@active == :runs} class="flex items-center gap-0.5 text-xs" aria-label="Sections">
          <.nav_link navigate={~p"/"} id="nav-chat">Chat</.nav_link>
          <.nav_link navigate={~p"/runs"} active id="nav-runs">Runs</.nav_link>
        </nav>
        <div class="ml-auto flex min-w-0 items-center gap-3">
          {render_slot(@status)}
          <.theme_toggle />
        </div>
      </header>

      <main class={["flex-1", @full && "flex min-h-0"]}>
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "rounded-md px-2 py-1 font-medium transition-colors focus-visible:outline-2 focus-visible:outline-bm-text",
        if(@active, do: "bg-bm-raised text-bm-text", else: "text-bm-muted hover:text-bm-text")
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-full border border-bm-line bg-bm-bg p-0.5">
      <div class="absolute inset-y-0.5 left-0.5 w-7 rounded-full bg-bm-raised transition-[left] duration-200 [[data-theme=light]_&]:left-[1.875rem] [[data-theme=dark]_&]:left-[3.625rem] [[data-theme-source=system]_&]:!left-0.5" />
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "System theme"},
            {"light", "hero-sun-micro", "Light theme"},
            {"dark", "hero-moon-micro", "Dark theme"}
          ]
        }
        class="relative flex w-7 cursor-pointer justify-center py-1 text-bm-muted transition-colors hover:text-bm-text"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end
end
