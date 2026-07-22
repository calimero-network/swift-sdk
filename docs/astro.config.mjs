// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// MeroKit documentation — Astro Starlight with the shared Calimero theme
// (Zinc + #a5ff11 lime), ported from calimero-network/core.
export default defineConfig({
  site: 'https://calimero-network.github.io',
  // GitHub project Pages serve under /<repo>/. Change if a custom domain is used.
  base: '/swift-sdk',
  integrations: [
    starlight({
      title: 'MeroKit',
      description:
        'The Calimero Swift SDK — a native, zero-dependency iOS/macOS client for a remote Calimero node: async/await auth with token refresh, JSON-RPC contract calls, the full admin API, SSO deep-link login, and a SwiftUI frontend layer.',
      logo: {
        light: './src/assets/logo-light.svg',
        dark: './src/assets/logo-dark.svg',
        alt: 'MeroKit',
      },
      favicon: '/favicon.svg',
      customCss: ['./src/styles/theme.css'],
      expressiveCode: {
        themes: ['github-dark', 'github-light'],
        styleOverrides: {
          borderRadius: '0.5rem',
          borderColor: 'var(--sl-color-gray-6)',
          codeBackground: 'var(--sl-color-gray-7)',
          codeFontFamily: 'var(--sl-font-mono)',
          frames: {
            editorTabBarBackground: 'var(--sl-color-gray-6)',
            terminalTitlebarBackground: 'var(--sl-color-gray-6)',
          },
        },
      },
      lastUpdated: true,
      editLink: {
        baseUrl: 'https://github.com/calimero-network/swift-sdk/edit/master/docs/',
      },
      head: [
        { tag: 'meta', attrs: { name: 'theme-color', content: '#09090b' } },
      ],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/calimero-network/swift-sdk',
        },
      ],
      // Explicit, grouped navigation: Get Started → Understand → Guides → Reference.
      sidebar: [
        { label: 'Home', link: '/' },
        {
          label: 'Get Started',
          items: ['get-started/quickstart', 'get-started/authentication'],
        },
        {
          label: 'Understand',
          items: ['understand/system-overview', 'understand/glossary'],
        },
        {
          label: 'Guides',
          items: [
            'guides/contexts-and-apps',
            'guides/executing-methods',
            'guides/groups-and-governance',
            'guides/blobs',
            'guides/swiftui-frontend',
          ],
        },
        {
          label: 'Reference',
          items: [
            'reference/mero',
            'reference/admin-api',
            'reference/auth-api',
            'reference/error-model',
          ],
        },
      ],
    }),
  ],
});
