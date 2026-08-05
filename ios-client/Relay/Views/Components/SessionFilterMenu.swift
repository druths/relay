import SwiftUI

/// Compact single-select filter chip for the sidebar's session filters
/// (Project + Label). Renders as a small capsule that reads
/// "Title: All" when unset or "Title: <value>" (with an inline × to
/// clear) when set. Tap opens a native `Menu` with the option list;
/// SwiftUI handles positioning + dismissal.
///
/// Both filters (project and label) share this view so they look and
/// behave identically. Search inside the menu isn't provided — SwiftUI's
/// `Menu` primitive doesn't support it, and typical relay users have
/// well under a dozen values per facet. If lists grow beyond that we
/// can swap the trigger for a sheet-based picker later.
struct SessionFilterMenu: View {
    /// Prefix shown in the button ("Project", "Label"). Kept short so
    /// two filters fit side by side even on a narrow sidebar.
    let title: String
    /// Options as `(value, display label)` pairs. For project filters
    /// the value is the project id, the label is the resolved name.
    let options: [Option]
    /// Currently-selected value, or nil for "no filter."
    let value: String?
    let onChange: (String?) -> Void

    @Environment(\.relayTheme) private var theme

    struct Option: Identifiable, Equatable {
        let value: String
        let label: String
        var id: String { value }
    }

    private var selectedLabel: String? {
        guard let v = value else { return nil }
        return options.first(where: { $0.value == v })?.label ?? v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Small caps label above the chip. Reads as a field-label
            // for the filter below rather than inline noise inside the
            // chip. Reserves the same vertical space whether or not a
            // filter is active so the row doesn't shift on selection.
            Text(title.uppercased())
                .font(theme.labelFont(size: 10))
                .tracking(1)
                .foregroundStyle(theme.textQuaternary)

            Menu {
                Button {
                    onChange(nil)
                } label: {
                    if value == nil {
                        Label("All", systemImage: "checkmark")
                    } else {
                        Text("All")
                    }
                }
                Divider()
                ForEach(options) { opt in
                    Button {
                        onChange(opt.value)
                    } label: {
                        if opt.value == value {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedLabel ?? "All")
                        .foregroundStyle(selectedLabel != nil ? .white : theme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Cap so a long project name doesn't blow out
                        // the chip and force the sidebar's outer
                        // layout to renegotiate widths.
                        .frame(maxWidth: 120, alignment: .leading)
                    if selectedLabel != nil {
                        // Dedicated clear button — tap dismisses the
                        // filter without opening the menu.
                        Button {
                            onChange(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.textQuaternary)
                    }
                }
                .font(theme.bodyFont(size: 13, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                // Render the capsule fill *as* the background rather
                // than filling a rectangle and clipping to a Capsule.
                // The separate `background(color) + clipShape(Capsule())`
                // combo shows a rectangle for a few frames while
                // SwiftUI applies the mask during Menu's press-in
                // animation — manifests as the chip briefly losing
                // its rounded ends when tapped.
                .background {
                    Capsule().fill(
                        selectedLabel != nil ? theme.primary : theme.primary.opacity(0.15),
                    )
                }
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }
}
