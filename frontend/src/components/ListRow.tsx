import { type ReactNode } from "react";

import { cn } from "../lib/utils";

export function ListRow({
  children,
  action,
  actionClassName,
  className,
}: {
  children: ReactNode;
  action?: ReactNode;
  actionClassName?: string;
  className?: string;
}) {
  return (
    <div
      className={cn(
        // Compact standard list row (Phase 10.6g density): less padding, tighter gaps
        "rounded-md border bg-card px-3 py-1.5 flex flex-col gap-1.5 sm:flex-row sm:items-center sm:justify-between sm:gap-3",
        className,
      )}
    >
      <div className="min-w-0 flex-1 leading-snug">{children}</div>
      {action && (
        <div className={cn("flex flex-wrap items-center gap-1.5 sm:shrink-0", actionClassName)}>
          {action}
        </div>
      )}
    </div>
  );
}
