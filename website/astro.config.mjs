import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Also protects direct `astro build` invocations outside the Makefile.
execFileSync(process.env.PYTHON ?? 'python3', [
  fileURLToPath(new URL('../tools/check_public_inputs.py', import.meta.url)),
], { stdio: 'inherit' });

export default defineConfig({
  integrations: [tailwind()],
  site: 'https://gridponder.org',
  base: process.env.GRIDPONDER_REPORT_BASE ?? '/',
});
