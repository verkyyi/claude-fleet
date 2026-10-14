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
    const known: Record<string, string> = { plus: "Plus", pro: "Pro", team: "Team", business: "Business", enterprise: "Enterprise", edu: "Edu", free: "Free" };
    return known[plan] || null;
  }
  return null;
}
