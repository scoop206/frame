# frame project config — keys: see the README's "config.sh" section
BUFFERS=(claude local vite)
VITE_DIR=.
WT_LINKS=(.env)
stack_up() {
  frame_clone_node_modules
}
