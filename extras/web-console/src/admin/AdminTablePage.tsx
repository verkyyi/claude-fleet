// AdminTablePage — the admin side's one page frame (EPIC #3923 C10; C11–C15
// reuse it): a title, KPI cards, a data table (sorting, a filter row,
// search, a click opens a row's Sheet). Only shadcn's own blocks put
// together — Card · Table (TanStack) · Input · ToggleGroup · Sheet · Skeleton ·
// Alert — never a component of our own.
import * as React from "react";
import {
  type ColumnDef,
  type SortingState,
  flexRender,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
} from "@tanstack/react-table";
import { AlertCircle, ArrowDown, ArrowUp, Search } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { t } from "./i18n";

export type Kpi = { label: string; value: React.ReactNode };
export type Filter<T> = { key: string; label: string; test: (row: T) => boolean };

export type AdminTablePageProps<T> = {
  title: string;
  lead?: string;
  // kpis are drawn from the loaded rows (and whatever else fetch carried)
  kpis?: (rows: T[]) => Kpi[];
  // cards between the KPIs and the table (the 发布 page's lanes and keys, C14)
  aside?: (rows: T[] | null) => React.ReactNode;
  columns: ColumnDef<T, any>[];
  fetch: () => Promise<T[]>;
  // actions sit at the head's right; reload re-runs fetch
  actions?: (reload: () => void, rows: T[]) => React.ReactNode;
  // nav sits under the head (a page's tabs, C11)
  nav?: React.ReactNode;
  filters?: Filter<T>[];
  // the filter a page opens on (default all)
  defaultFilter?: string;
  onFilter?: (key: string) => void;
  // a page's own narrowing on top (a person, a time range), and its controls
  where?: (row: T) => boolean;
  toolbar?: React.ReactNode;
  // the text a row is searched by
  searchText?: (row: T) => string;
  rowId: (row: T) => string;
  // the open row's id (the page's route says it), and the way to change it
  openId?: string | null;
  onOpen?: (id: string | null) => void;
  drawer?: (row: T, ctx: { close: () => void; reload: () => void }) => React.ReactNode;
  // what an empty table says when there is no row at all (a filter that
  // matches nothing says table.empty)
  emptyText?: string;
};

export function AdminTablePage<T>(p: AdminTablePageProps<T>) {
  const [rows, setRows] = React.useState<T[] | null>(null);
  const [error, setError] = React.useState<string>("");
  const [query, setQuery] = React.useState("");
  const [filter, setFilter] = React.useState(p.defaultFilter || "all");
  const [sorting, setSorting] = React.useState<SortingState>([]);
  const fetchRef = React.useRef(p.fetch);
  fetchRef.current = p.fetch;

  const reload = React.useCallback(() => {
    setError("");
    fetchRef.current().then(setRows, (e: Error) => setError(e.message));
  }, []);
  React.useEffect(reload, [reload]);

  const shown = React.useMemo(() => {
    const f = p.filters?.find((x) => x.key === filter);
    return (rows || []).filter((r) => (!f || f.test(r)) && (!p.where || p.where(r)));
  }, [rows, filter, p.filters, p.where]);

  const table = useReactTable({
    data: shown,
    columns: p.columns,
    state: { sorting, globalFilter: query },
    onSortingChange: setSorting,
    onGlobalFilterChange: setQuery,
    globalFilterFn: (row, _id, q: string) => !q || (p.searchText?.(row.original) || "").toLowerCase().includes(q.trim().toLowerCase()),
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getRowId: (r) => p.rowId(r),
  });

  const open = p.openId && rows ? rows.find((r) => p.rowId(r) === p.openId) : undefined;
  const kpis = rows && p.kpis ? p.kpis(rows) : null;
  const visible = table.getRowModel().rows;

  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 p-6 md:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <h1 className="font-display text-3xl font-semibold tracking-tight">
            {p.title}
            <span className="text-primary">.</span>
          </h1>
          {p.lead && <p className="mt-1 text-sm text-muted-foreground">{p.lead}</p>}
        </div>
        {p.actions && <div className="flex gap-2">{p.actions(reload, rows || [])}</div>}
      </div>

      {p.nav}

      {p.kpis && (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          {(kpis || [0, 1, 2, 3].map(() => null)).map((k, i) => (
            <Card key={i} className="gap-0 py-4">
              <CardContent className="px-5">
                {k ? (
                  <>
                    <p className="font-display text-2xl font-semibold tabular-nums">{k.value}</p>
                    <p className="text-xs text-muted-foreground">{k.label}</p>
                  </>
                ) : (
                  <>
                    <Skeleton className="mb-2 h-7 w-12" />
                    <Skeleton className="h-3 w-20" />
                  </>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      {p.aside?.(rows)}

      {error ? (
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>{t("state.error")}</AlertTitle>
          <AlertDescription className="flex flex-wrap items-center gap-3">
            <span className="font-mono text-xs">{error}</span>
            <Button size="sm" variant="outline" onClick={reload}>
              {t("state.retry")}
            </Button>
          </AlertDescription>
        </Alert>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-3">
            {p.searchText && (
              <div className="relative w-full max-w-xs">
                <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  placeholder={t("table.search", { title: p.title })}
                  aria-label={t("table.search", { title: p.title })}
                  className="pl-8"
                />
              </div>
            )}
            {p.filters && (
              <ToggleGroup type="single" variant="outline" size="sm" value={filter} onValueChange={(v) => {
                  if (!v) return;
                  setFilter(v);
                  p.onFilter?.(v);
                }}>
                <ToggleGroupItem value="all" className="px-3">
                  {t("filter.all")}
                </ToggleGroupItem>
                {p.filters.map((f) => (
                  <ToggleGroupItem key={f.key} value={f.key} className="px-3">
                    {f.label}
                  </ToggleGroupItem>
                ))}
              </ToggleGroup>
            )}
            {p.toolbar}
            {rows && (
              <span className="ml-auto font-mono text-xs text-muted-foreground">
                {t("table.rows", { n: visible.length, total: rows.length })}
              </span>
            )}
          </div>

          <div className="overflow-hidden rounded-xl border bg-card">
            <Table>
              <TableHeader>
                {table.getHeaderGroups().map((hg) => (
                  <TableRow key={hg.id} className="hover:bg-transparent">
                    {hg.headers.map((h) => {
                      const dir = h.column.getIsSorted();
                      return (
                        <TableHead key={h.id} className="h-11 px-4">
                          {h.isPlaceholder ? null : h.column.getCanSort() ? (
                            <button className="inline-flex items-center gap-1 font-medium hover:text-foreground" onClick={h.column.getToggleSortingHandler()}>
                              {flexRender(h.column.columnDef.header, h.getContext())}
                              {dir === "asc" ? <ArrowUp className="size-3.5" /> : dir === "desc" ? <ArrowDown className="size-3.5" /> : null}
                            </button>
                          ) : (
                            flexRender(h.column.columnDef.header, h.getContext())
                          )}
                        </TableHead>
                      );
                    })}
                  </TableRow>
                ))}
              </TableHeader>
              <TableBody>
                {!rows ? (
                  [0, 1, 2, 3, 4].map((i) => (
                    <TableRow key={i}>
                      {p.columns.map((_c, j) => (
                        <TableCell key={j} className="px-4 py-3">
                          <Skeleton className="h-4 w-full max-w-28" />
                        </TableCell>
                      ))}
                    </TableRow>
                  ))
                ) : visible.length ? (
                  visible.map((r) => (
                    <TableRow
                      key={r.id}
                      data-state={r.id === p.openId ? "selected" : undefined}
                      className={p.onOpen ? "cursor-pointer" : undefined}
                      onClick={() => p.onOpen?.(r.id)}
                    >
                      {r.getVisibleCells().map((c) => (
                        <TableCell key={c.id} className="px-4 py-3">
                          {flexRender(c.column.columnDef.cell, c.getContext())}
                        </TableCell>
                      ))}
                    </TableRow>
                  ))
                ) : (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={p.columns.length} className="h-32 text-center text-muted-foreground">
                      <p>{(!rows.length && p.emptyText) || t("table.empty")}</p>
                      {(query || filter !== (p.defaultFilter || "all")) && (
                        <Button
                          variant="link"
                          size="sm"
                          onClick={() => {
                            setQuery("");
                            setFilter(p.defaultFilter || "all");
                            p.onFilter?.(p.defaultFilter || "all");
                          }}
                        >
                          {t("table.clear")}
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          </div>
        </>
      )}

      {p.drawer && (
        <Sheet open={!!open} onOpenChange={(o) => !o && p.onOpen?.(null)}>
          <SheetContent className="w-full gap-0 overflow-y-auto sm:max-w-lg">
            {open && p.drawer(open, { close: () => p.onOpen?.(null), reload })}
          </SheetContent>
        </Sheet>
      )}
    </div>
  );
}
