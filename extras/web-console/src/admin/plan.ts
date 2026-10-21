// Only provider values are interpreted. A label (e.g. Charlie_20X) is never evidence.
export function planName(provider: string, raw: string, tier = ""): string | null {
  const plan = raw.trim().toLowerCase();
  if (provider === "claude") {
    if (plan === "max") {
      if (tier === "default_claude_max_5x") return "Max 5×";
      if (tier === "default_claude_max_20x") return "Max 20×";
      return "Max";
    }
    if (plan === "pro") return "Pro";
    if (plan === "team") return "Team";
    if (plan === "enterprise") return "Enterprise";
  }
  if (provider === "codex") {
    const known: Record<string, string> = { plus: "Plus", pro: "Pro", prolite: "Pro Lite", promax: "Pro Max", team: "Team", business: "Business", enterprise: "Enterprise", edu: "Edu", free: "Free" };
    return known[plan] || null;
  }
  return null;
}

// monthlyLabel is what a plan costs a month as the hub priced it
// (subscription_plans, claude-fleet EEJD): 「$200/月」; "" when nobody priced it.
export function monthlyLabel(cost: number | null | undefined, currency = "USD", per = "/mo"): string {
  if (cost == null || !Number.isFinite(Number(cost))) return "";
  const n = Number(cost);
  const amt = Number.isInteger(n) ? String(n) : n.toFixed(2);
  return (currency === "USD" ? `$${amt}` : `${amt} ${currency}`) + per;
}
