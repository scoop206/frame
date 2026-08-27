import { defineConfig } from 'astro/config';

// Bind Astro's dev server (which IS vite) to the port frame allocated for this
// frame's vite buffer. frame exports FRAME_VITE_PORT — a per-frame, upward-
// scanned port so sibling worktrees never collide. VITE_PORT is the config base
// and 4321 is Astro's own default for a plain `npm run dev` outside frame.
export default defineConfig({
  devToolbar: { enabled: false },
  server: {
    port: Number(process.env.FRAME_VITE_PORT ?? process.env.VITE_PORT ?? 4321),
    host: true,
  },
});
