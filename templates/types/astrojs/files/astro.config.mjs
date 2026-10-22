import { defineConfig } from 'astro/config';

// Let Vite pick the port: it walks up from 4321 to the first open one, so
// sibling frames never collide without anyone prescribing a port. host:true
// binds to the network. Read the actual port off the vite buffer's
// `Local http://localhost:PORT/` line.
export default defineConfig({
  devToolbar: { enabled: false },
  server: {
    host: true,
  },
});
