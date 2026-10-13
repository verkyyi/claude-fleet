// api.ts — the admin side's one road to the hub: same-origin fetch of the
// existing /v1 reads and writes (EPIC #3923 rule 7). A refusal throws ApiError
// with the hub's own words. A demo build (VITE_DEMO=1, the clickable prototype
// of rule 14) answers from demo.ts instead and never touches a network.
import { demoApi } from "./demo";

export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export type ApiInit = { method?: string; json?: unknown };

const DEMO = import.meta.env.VITE_DEMO === "1";

export async function api<T = any>(url: string, init: ApiInit = {}): Promise<T> {
  if (DEMO) return demoApi(url, init) as Promise<T>;
  const req: RequestInit = { credentials: "same-origin", headers: { Accept: "application/json" }, method: init.method };
  if (init.json !== undefined) {
    req.method = init.method || "POST";
    req.headers = { Accept: "application/json", "Content-Type": "application/json" };
    req.body = JSON.stringify(init.json);
  }
  const r = await fetch(url, req);
  const text = await r.text();
  let body: any = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  if (!r.ok) {
    // a fleet tool's refusal is {error: {code, message}} (claude-fleet#2527)
    const why = body && (body.error && typeof body.error === "object" ? body.error.message : body.error || body.message);
    throw new ApiError(why || `${r.status} ${r.statusText}`.trim(), r.status);
  }
  return body as T;
}

// The shapes this side reads, field for field as the hub writes them.

export type PersonLogin = { hostname: string; login: string; state: string; home?: boolean; kind: "node" | "client" };

export type HubUser = {
  principal_id: string;
  principal: string;
  github_id: number;
  login: string;
  role: "user" | "admin";
  machine_login?: string;
  added_by?: string;
  added_at?: string;
  last_seen?: string;
  deploy?: boolean;
  logins: PersonLogin[];
  via?: string[];
};

export type DeployAdmin = { login: string; github_id?: number; pinned: boolean; logins: PersonLogin[] };
export type UsersList = { users: HubUser[]; admins: DeployAdmin[]; added?: string; github_id?: number; removed?: string; devices_revoked?: number };

export type Invite = {
  id: string;
  github_login?: string;
  email?: string;
  created_by?: string;
  created_at: string;
  expires_at: string;
  used_at?: string;
  used_by?: string;
  revoked_at?: string;
  state: "active" | "used" | "revoked" | "expired";
};
export type InviteCreated = Invite & { code: string; url: string; command: string };

export type PersonBudget = {
  principal: string;
  display_name?: string;
  limit_5h?: number;
  limit_week?: number;
  used_5h?: number;
  used_week?: number;
  over?: boolean;
};

export type NodeMachine = { hostname?: string; spare?: number; spare_target?: number; logins_used?: number; login_cap?: number };

export type Me = { role?: string; person?: string; name?: string; login?: string };

// cred-policy (claude-fleet#3713): who may use which subscription.
export type PolicyEntry = { id: string; allow: string[]; all?: boolean; error?: string };
export type PolicyView = { mode?: "legacy" | "strict"; users?: PolicyEntry[]; nodes?: PolicyEntry[] };
export type Credential = { provider: string; account: string; account_uuid?: string; principal_id?: string };
export type Limits = { per_account?: { account_uuid?: string; limits?: Record<string, any> }[] };
