# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
# NAME isn't set: it defaults to the checkout's directory name.

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json). A static site has no backend, so no server/ngrok here —
# the vite buffer runs the Astro dev server.
BUFFERS=(claude local vite)

# The vite buffer runs `npm run dev` in $VITE_DIR (default `web`). Astro
# apps conventionally live at the repo root, so point it there.
VITE_DIR=.

# Base dev-server port (Astro's stock 4321); each frame scans upward from it
# and exports the pick as FRAME_VITE_PORT for astro.config.mjs to read (see
# examples/README.md for the app-side snippet).
VITE_PORT=4321

# Gitignored assets symlinked into fresh worktrees. The default list covers
# .env and web/node_modules; a root-dir npm app wants node_modules itself.
WT_LINKS=(node_modules)
