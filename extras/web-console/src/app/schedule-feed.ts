export type ScheduleRead<T> = { kind: "ok"; data: T } | { kind: "expired" | "error" };

// Background metadata must never navigate away from a live conversation or
// terminal. Expiry fences both future reads and older in-flight responses.
export class ScheduleReader {
  private expired = false;
  async read<T>(url: string): Promise<ScheduleRead<T>> {
    if (this.expired) return { kind: "expired" };
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" });
      if (response.status === 401) this.expired = true;
      if (this.expired) return { kind: "expired" };
      if (!response.ok) return { kind: "error" };
      const data = await response.json() as T;
      return this.expired ? { kind: "expired" } : { kind: "ok", data };
    } catch {
      return { kind: this.expired ? "expired" : "error" };
    }
  }
}
