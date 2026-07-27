# frame deploy-sans-tests — trigger the project's deploy workflow with tests
# skipped. The repo is inferred from the checkout's origin remote; override
# the workflow file with DEPLOY_WORKFLOW in .frame/config.sh.
# Sourced by bin/frame; helpers + set -euo pipefail already active.

frame_load_config
cd "$PROJECT_ROOT"

gh workflow run "${DEPLOY_WORKFLOW:-deploy.yml}" --ref main -f skip_tests=true
echo "✓ deploy workflow dispatched (skip_tests=true)"
