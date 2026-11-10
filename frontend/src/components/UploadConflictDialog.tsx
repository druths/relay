export type ConflictChoice = "replace" | "keep-both" | "skip";

/** Asks what to do with uploads whose names already exist in the target
 *  folder. One choice covers every clashing file in the batch; files
 *  without a clash upload regardless. Dismissing counts as Skip. */
export function UploadConflictDialog({
  names, folder, onChoose,
}: {
  names: string[];
  folder: string;
  onChoose: (choice: ConflictChoice) => void;
}) {
  const many = names.length > 1;
  return (
    <div
      className="fixed inset-0 z-[200] flex items-center justify-center bg-black/60 p-4"
      onClick={() => onChoose("skip")}
    >
      <div
        className="w-full max-w-md bg-gray-900 border border-gray-700 rounded-xl shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-5 py-4 border-b border-gray-800">
          <h3 className="text-sm font-semibold text-gray-100">
            {many ? `${names.length} files already exist` : "File already exists"}
          </h3>
          <p className="mt-1 text-xs text-gray-500 truncate">in {folder || "the root folder"}</p>
        </div>
        <div className="px-5 py-4 text-xs text-gray-300 space-y-3">
          <ul className="max-h-40 overflow-y-auto font-mono text-[11px] text-gray-200 space-y-0.5">
            {names.map((n) => <li key={n} className="truncate">{n}</li>)}
          </ul>
          <p className="text-[11px] text-gray-500 leading-relaxed">
            Replace overwrites {many ? "them" : "it"}. Keep both uploads
            {many ? " each" : ""} under a new name, like “report (1).pdf”.
          </p>
        </div>
        <div className="px-5 py-3 border-t border-gray-800 flex justify-end gap-2">
          <button
            onClick={() => onChoose("skip")}
            className="px-3 py-1.5 text-xs text-gray-300 hover:text-white transition-colors"
          >
            Skip
          </button>
          <button
            onClick={() => onChoose("keep-both")}
            className="px-3 py-1.5 text-xs bg-gray-700 hover:bg-gray-600 text-white rounded transition-colors"
          >
            Keep both
          </button>
          <button
            onClick={() => onChoose("replace")}
            className="px-3 py-1.5 text-xs bg-red-600 hover:bg-red-500 text-white rounded transition-colors"
          >
            Replace
          </button>
        </div>
      </div>
    </div>
  );
}

/** `name` with " (n)" before the extension, using the lowest n not in
 *  `taken`: "report.pdf" → "report (1).pdf", "Makefile" → "Makefile (1)". */
export function uniqueName(name: string, taken: Set<string>): string {
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : "";
  for (let n = 1; ; n++) {
    const candidate = `${stem} (${n})${ext}`;
    if (!taken.has(candidate)) return candidate;
  }
}
