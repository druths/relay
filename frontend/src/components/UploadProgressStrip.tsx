import type { UploadItem } from "../types";

interface Props {
  uploads: UploadItem[];
  onCancel: (id: string) => void;
  onDismiss: (id: string) => void;
}

function _formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/// Slim strip of in-flight and recently-completed uploads. Rendered
/// wherever an upload origin lives — above the input bar for chat
/// uploads, at the top of the file browser for browser uploads. The
/// caller filters `uploads` down to just the origin/scope relevant
/// to their surface; this component renders whatever it's handed.
///
/// Successful rows self-fade via a timer in the parent registry;
/// failed rows persist until the user hits the `×` dismiss button.
/// In-flight rows show a cancel `×` that aborts the underlying XHR.
export function UploadProgressStrip({ uploads, onCancel, onDismiss }: Props) {
  if (uploads.length === 0) return null;
  return (
    <div className="border-t border-gray-800 bg-gray-950/80 backdrop-blur px-3 py-2 space-y-1.5">
      {uploads.map((u) => {
        const pct = u.sizeBytes > 0
          ? Math.min(100, Math.round((u.uploadedBytes / u.sizeBytes) * 100))
          : (u.status === "done" ? 100 : 0);
        const isFailed = u.status === "failed";
        const isDone = u.status === "done";
        const isCancelled = u.status === "cancelled";
        return (
          <div key={u.id} className="flex items-center gap-2 text-xs">
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 mb-0.5">
                <span
                  className="font-mono text-gray-300 truncate"
                  title={u.filename}
                  style={{ direction: "rtl", textAlign: "left" }}
                >
                  {/* RTL trick truncates the filename in the middle. */}
                  {u.filename}
                </span>
                <span className={`shrink-0 text-[11px] ${
                  isFailed ? "text-red-400"
                    : isDone ? "text-emerald-400"
                    : isCancelled ? "text-gray-500"
                    : "text-gray-500"
                }`}>
                  {isFailed ? "Failed"
                    : isDone ? "Done"
                    : isCancelled ? "Cancelled"
                    : `${_formatSize(u.uploadedBytes)} / ${_formatSize(u.sizeBytes)}`}
                </span>
              </div>
              <div className="h-1 rounded-full bg-gray-800 overflow-hidden">
                <div
                  className={`h-full transition-all duration-150 ${
                    isFailed ? "bg-red-600"
                      : isDone ? "bg-emerald-600"
                      : isCancelled ? "bg-gray-600"
                      : "bg-blue-600"
                  }`}
                  style={{ width: `${pct}%` }}
                />
              </div>
              {isFailed && u.error && (
                <div className="mt-0.5 text-[10px] text-red-400 truncate" title={u.error}>
                  {u.error}
                </div>
              )}
            </div>
            <button
              onClick={() => (u.status === "uploading" ? onCancel(u.id) : onDismiss(u.id))}
              title={u.status === "uploading" ? "Cancel upload" : "Dismiss"}
              className="shrink-0 w-5 h-5 flex items-center justify-center rounded
                         text-gray-500 hover:text-white hover:bg-gray-800 transition-colors"
            >
              <svg viewBox="0 0 16 16" width="10" height="10" fill="currentColor" aria-hidden>
                <path d="M4.28 3.22a.75.75 0 00-1.06 1.06L6.94 8l-3.72 3.72a.75.75 0 101.06 1.06L8 9.06l3.72 3.72a.75.75 0 101.06-1.06L9.06 8l3.72-3.72a.75.75 0 00-1.06-1.06L8 6.94 4.28 3.22z"/>
              </svg>
            </button>
          </div>
        );
      })}
    </div>
  );
}
