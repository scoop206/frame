# Frame project config — committed project facts (like an .env.dev + hooks).
# Personal overrides go in .frame/local/config.sh (gitignored, wins over this).
NAME=astrojs

# NAME feeds PORT_PREFIX (upcased, hyphens → underscores). If you name the
# project after its domain (NAME=example.com), the dot survives into the
# derived prefix — not a legal env-var name — so override it explicitly:
#PORT_PREFIX=EXAMPLE_COM

# Required: which buffers each frame opens (definitions live in frame's
# buffers.json). A static site has no backend, so no server/ngrok here —
# the vite buffer runs the Astro dev server.
BUFFERS=(claude local vite)

# The vite buffer runs `npm run dev` in $VITE_DIR (default `web`). Astro
# apps conventionally live at the repo root, so point it there.
VITE_DIR=.

# Base dev-server port (Astro's stock 4321); each frame scans upward from it
# and exports the pick as ${PORT_PREFIX}_VITE_PORT for astro.config.mjs to
# read (see examples/README.md for the app-side snippet).
VITE_PORT=4321

# Gitignored assets symlinked into fresh worktrees. The default list covers
# .env and web/node_modules; a root-dir npm app wants node_modules itself.
WT_LINKS=(node_modules)
