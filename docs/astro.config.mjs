// @ts-check
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// Project page on GitHub Pages is served from a sub-path, so `base` must match
// the repository name. If you later add a custom domain, set `site` to it and
// change `base` to "/".
export default defineConfig({
  site: "https://christestet.github.io",
  base: "/ssh-tunnel",
  integrations: [
    starlight({
      title: "SSH Tunnel",
      description:
        "Native macOS menu bar app for opening, monitoring, and closing SSH tunnels from your existing SSH config.",
      logo: {
        src: "./src/assets/ssh-tunnel.png",
        alt: "SSH Tunnel app icon",
      },
      favicon: "/favicon.png",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/christestet/ssh-tunnel",
        },
      ],
      editLink: {
        baseUrl:
          "https://github.com/christestet/ssh-tunnel/edit/main/docs/",
      },
      lastUpdated: true,
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
      sidebar: [
        {
          label: "Getting Started",
          items: [
            { label: "Install", slug: "getting-started/install" },
            {
              label: "Configure SSH",
              slug: "getting-started/configure-ssh",
            },
          ],
        },
        {
          label: "Guides",
          items: [
            { label: "Features", slug: "features" },
            { label: "Using the App", slug: "guides/using-the-app" },
            { label: "Settings", slug: "guides/settings" },
            { label: "Quick Forwards", slug: "guides/quick-forwards" },
            {
              label: "Health Checks & Reconnects",
              slug: "guides/health-checks",
            },
            {
              label: "Terminal Coexistence",
              slug: "guides/terminal-coexistence",
            },
            { label: "Updates", slug: "guides/updates" },
          ],
        },
        {
          label: "Reference",
          items: [
            {
              label: "SSH Command Mapping",
              slug: "reference/ssh-command-mapping",
            },
            { label: "Debugging & Logs", slug: "reference/debugging" },
            { label: "Build & Test", slug: "reference/build-and-test" },
            { label: "Release Process", slug: "reference/release-process" },
          ],
        },
        {
          label: "More",
          items: [
            { label: "FAQ & Troubleshooting", slug: "faq" },
            { label: "Changelog", slug: "changelog" },
          ],
        },
      ],
    }),
  ],
});
