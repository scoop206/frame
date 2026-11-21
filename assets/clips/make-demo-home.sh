#!/usr/bin/env zsh
# make-demo-home.sh [DIR] — build the sandbox HOME the landing-page clips are
# recorded in (default /Users/Shared/frame-demo). It holds three small demo
# repos and four real claude sessions in them, so `frame shell --recent` shows
# demo work instead of your own session titles, which would end up on the web.
#
# The path is printed by frame's boot lines, so keep it neutral (no username).
# Costs four short claude calls (sonnet). macOS: ~/Library is symlinked in so
# claude finds its login in your keychain.
emulate -L zsh
set -euo pipefail

H=${1:-/Users/Shared/frame-demo}
[[ -e "$H" ]] && { print -u2 "✗ $H exists — remove it first"; exit 1; }
for c in claude jq git perl; do (( $+commands[$c] )) || { print -u2 "✗ needs $c"; exit 1; }; done

C=$H/code
mkdir -p $H/.claude $H/.config/nvim $C/acme-api/src $C/acme-web/src/checkout $C/acme-infra/staging
[[ "$OSTYPE" == darwin* ]] && ln -s ~/Library $H/Library

cat > $C/acme-api/src/webhooks.ts <<'EOF'
import { db } from "./db";
import { charge } from "./payments";

const MAX_RETRIES = 3;

export async function handleCheckoutWebhook(event: CheckoutEvent) {
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    const res = await charge(event.customerId, event.amountCents);
    if (res.ok) {
      await db.orders.markPaid(event.orderId);
      return;
    }
    // a 502 from the processor may still have charged the card
    if (res.status === 502) continue;
    throw new Error(`charge failed: ${res.status}`);
  }
}
EOF
cat > $C/acme-api/src/rate_limit.ts <<'EOF'
const WINDOW_MS = 60_000;
const LIMIT = 120;

// in-memory sliding window, keyed by API token
const hits = new Map<string, number[]>();

export function allow(token: string, now = Date.now()): boolean {
  const recent = (hits.get(token) ?? []).filter((t) => now - t < WINDOW_MS);
  if (recent.length >= LIMIT) return false;
  recent.push(now);
  hits.set(token, recent);
  return true;
}
EOF
cat > $C/acme-web/src/checkout/Cart.tsx <<'EOF'
export function Cart({ items, onCheckout }: CartProps) {
  const subtotal = items.reduce((s, i) => s + i.priceCents * i.qty, 0);
  return (
    <section className="cart">
      {items.map((i) => (
        <div key={i.sku} className="line">{i.name} × {i.qty}</div>
      ))}
      <footer>Subtotal: {formatCents(subtotal)}</footer>
      <button onClick={onCheckout}>Check out</button>
    </section>
  );
}
EOF
cat > $C/acme-infra/staging/main.tf <<'EOF'
module "api" {
  source      = "../modules/api"
  environment = "staging"
  session_ttl = "1h"
  replicas    = 2
}
EOF
for r in acme-api acme-web acme-infra; do
  (cd $C/$r && git init -q && git add -A \
    && git -c user.name=demo -c user.email=demo@example.com commit -qm init)
done

# The demo's neovim: <leader>L sends a selection to the frame's claude.
cat > $H/.config/nvim/init.lua <<'EOF'
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.cursorline = true
vim.keymap.set("x", "<leader>l", ":FrameClaude ")
EOF

# seed REPO AGE_SECONDS PROMPT — one real session, made to look AGE old and
# interactive (frame's lists skip headless `claude -p` runs, entrypoint sdk-cli).
seed() {
  local repo=$1 age=$2 prompt=$3 f when stamp
  (cd $C/$repo && HOME=$H claude -p "$prompt" --allowedTools Read Grep Glob --model sonnet >/dev/null)
  f=$(grep -lF -- "$prompt" $H/.claude/projects/*/*.jsonl | head -1)
  when=$(( EPOCHSECONDS - age ))
  stamp=$(TZ=UTC strftime '%Y-%m-%dT%H:%M:%S' $when)
  perl -pi -e 's/"entrypoint":"sdk-cli"/"entrypoint":"cli"/g;
               s/"timestamp":"[0-9T:.-]+Z"/"timestamp":"'$stamp'.000Z"/g' "$f"
  touch -t $(strftime '%Y%m%d%H%M.%S' $when) "$f"
}
zmodload zsh/datetime
seed acme-web   $(( 4*86400 ))  "plan the cart refactor: split Cart.tsx into line items and a summary, keep the props API. plan only"
seed acme-infra $(( 2*86400 ))  "bump the session TTL to 24h in staging only, and tell me what else reads that value. plan first, no edits yet"
seed acme-api   $(( 86400 - 3600 )) "rate limiter: why does the sliding window reset on every deploy? read src/rate_limit.ts and explain, no edits"
seed acme-api   1200            "checkout webhooks are double-charging when the processor returns 502. find where the retry happens and propose an idempotency fix. don't change code yet"

# Interactive claude needs onboarding done and the demo dirs trusted.
jq --arg a $C/acme-api --arg w $C/acme-web --arg i $C/acme-infra '
  .hasCompletedOnboarding = true | .theme = "dark"
  | .projects[$a].hasTrustDialogAccepted = true
  | .projects[$w].hasTrustDialogAccepted = true
  | .projects[$i].hasTrustDialogAccepted = true' $H/.claude.json > $H/.claude.json.tmp
mv $H/.claude.json.tmp $H/.claude.json

print "✓ demo home ready: $H"
print "  record with: assets/clips/record.sh assets/resume.tape   (DEMO_HOME=$H)"
