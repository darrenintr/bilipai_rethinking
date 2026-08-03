// @ts-check
import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  output: 'server',
  adapter: cloudflare({
    // Astro's default Cloudflare adapter reads PUBLIC_* env vars from the
    // Pages env at runtime; no platformProxy needed in v11+.
  }),
  server: {
    port: 4321,
  },
  vite: {
    server: {
      // Proxy /api/* to the local Worker in dev. Production uses CORS +
      // the deployed worker URL via PUBLIC_WORKER_URL.
      proxy: {
        '/api': {
          target: 'http://127.0.0.1:8787',
          changeOrigin: true,
        },
      },
    },
  },
});
