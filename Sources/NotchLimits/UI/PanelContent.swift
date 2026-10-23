import SwiftUI

/// The open-state panel content: token hero, header, account rows, footer.
/// Laid out at its natural intrinsic height (MorphShell owns the height cap
/// and clips to it; Snapshot passes the same list cap). `width`
/// tracks the wrap shape's actual open width (`openWidth(notchWidth:
/// columns:)`), since that varies by machine and by how many columns have
/// rows. `notchHeight` insets all content below the physical notch band
/// (also machine-varying) so nothing ever sits above the cutout — the band
/// beside/around the notch stays pure contentless glass. When more than one
/// account group has rows the list splits into side-by-side columns —
/// Claude Max, Claude Team, Codex, in that order, empty groups dropped —
/// each under its own header, while the hero and footer keep the full width.
/// A single non-empty group falls back to the original one-column list.
@MainActor
struct PanelContent: View {
    @ObservedObject var store: UsageStore
    /// Not observed here: TokenHero observes it, so a ticking total redraws
    /// the hero alone, never the account rows.
    let tokens: TokenStore
    var onQuit: () -> Void = {}
    var width: CGFloat = 396
    var notchHeight: CGFloat = 32
    /// Vertical space available for the account list (panel cap minus
    /// hero/header/footer). nil = lay out naturally.
    /// When the rows outgrow it, the live list scrolls, never clips.
    var maxListHeight: CGFloat? = nil
    /// Snapshot turns this off: ImageRenderer draws a ScrollView's content
    /// as nothing, so its capped list shows the top rows that fit instead.
    var scrollsList = true

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 26
    /// Hero + header + footer: everything but the account list.
    static let chromeHeight = TokenHero.height + headerHeight + footerHeight

    /// Per-column width, narrowed from the old single-column 405 so three
    /// columns plus two gaps clear a 14" MacBook Pro (~1512pt) and the
    /// synthetic band with the window's side margins. The floor is the row's
    /// own content: up to three meters (a Max account carries 5h · 7d ·
    /// Fable), the big percentage and the Switch button must not clip, though
    /// the longest emails may ellipsize. 185 (the notch) + 210 = 395 sits
    /// just above that floor; three of them total 1209pt open / 1289pt
    /// window, which centers on a 1512pt screen with ~110pt to spare a side.
    static func columnWidth(notchWidth: CGFloat) -> CGFloat { notchWidth + 210 }
    static let columnGap: CGFloat = 12
    /// Open width for `columns` (1, 2, or 3) side-by-side columns.
    static func openWidth(notchWidth: CGFloat, columns: Int) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return columnWidth(notchWidth: notchWidth) * n + columnGap * (n - 1)
    }

    /// The width of one column given the current total `width` and how many
    /// columns share it — the inverse of `openWidth`, so the columns tile the
    /// panel exactly whether there are 1, 2, or 3 of them.
    private func columnWidth(count: Int) -> CGFloat {
        let n = CGFloat(max(1, count))
        return (width - Self.columnGap * (n - 1)) / n
    }

    var body: some View {
        VStack(spacing: 0) {
            TokenHero(tokens: tokens)
            if store.columnCount >= 2 {
                columnHeaders
            } else {
                header
            }
            accountsList
            footer
        }
        .padding(.top, notchHeight)
        .frame(width: width)
        .fontDesign(.rounded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeSpark().fill(Ink.coral).frame(width: 16, height: 16)
            Text("Claude Limits")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.primary)

            Spacer(minLength: 8)

            headerControls
        }
        .padding(.horizontal, 16)
        .frame(height: Self.headerHeight)
    }

    /// One header per visible column — "Claude Max" / "Claude Team" / "Codex"
    /// over their own column, each sized the same as the rows beneath it. The
    /// shared controls (updated time, refresh, quit) ride the far right of
    /// the last column only.
    private var columnHeaders: some View {
        let columns = store.visibleColumns
        return HStack(spacing: Self.columnGap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                columnHeader(kind: column.kind, isLast: index == columns.count - 1)
                    .frame(width: columnWidth(count: columns.count))
            }
        }
        .frame(height: Self.headerHeight)
    }

    @ViewBuilder
    private func columnHeader(kind: UsageStore.PanelColumn, isLast: Bool) -> some View {
        HStack(spacing: 8) {
            columnHeaderIcon(kind)
                .frame(width: 16, height: 16)
            Text(columnTitle(kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Spacer(minLength: isLast ? 8 : 0)

            if isLast { headerControls }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func columnHeaderIcon(_ kind: UsageStore.PanelColumn) -> some View {
        switch kind {
        case .max, .team:
            // Both are Claude, so both wear the Claude spark.
            ClaudeSpark().fill(Ink.coral)
        case .codex:
            // A hand-drawn OpenAI-style knot, not an SF Symbol or an asset.
            OpenAIMark().stroke(Ink.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }

    private func columnTitle(_ kind: UsageStore.PanelColumn) -> String {
        switch kind {
        case .max: return "Claude Max"
        case .team: return "Claude Team"
        case .codex: return "Codex"
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(updatedRelativeString(now: context.date))
                .font(.system(size: 10))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
        }

        Button(action: { store.refreshNow() }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
        }
        .buttonStyle(.plain)

        Button(action: onQuit) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Ink.muted)
        }
        .buttonStyle(.plain)
    }

    private func updatedRelativeString(now: Date) -> String {
        guard let last = store.lastUpdated else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        if seconds < 60 { return "updated \(seconds)s ago" }
        if seconds < 3600 { return "updated \(seconds / 60)m ago" }
        return "updated \(seconds / 3600)h ago"
    }

    // MARK: - Account rows

    /// Natural (unscrolled) height of the rows stack — fixed constants, so
    /// the scroll decision is deterministic arithmetic, not measurement.
    private var naturalListHeight: CGFloat {
        let count = CGFloat(store.listRowCount)
        return count * AccountRow.height + max(0, count - 1)  // rows + 1pt separators
    }

    /// Both columns scroll together, as the single list does.
    @ViewBuilder
    private var accountsList: some View {
        if let cap = maxListHeight, naturalListHeight > cap {
            if scrollsList {
                ScrollView(.vertical) { listStack }
                    .frame(height: cap)
            } else {
                listStack.frame(height: cap, alignment: .top).clipped()
            }
        } else {
            listStack
        }
    }

    @ViewBuilder
    private var listStack: some View {
        let columns = store.visibleColumns
        if columns.count >= 2 {
            HStack(alignment: .top, spacing: Self.columnGap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    rowsStack(column.accounts, codexNames: column.kind == .codex)
                        .frame(width: columnWidth(count: columns.count))
                }
            }
        } else {
            // One or zero non-empty groups: the original single list, whose
            // Max-only form is byte-identical to the pre-column look.
            rowsStack(store.accounts, codexNames: columns.first?.kind == .codex)
        }
    }

    private func rowsStack(_ accounts: [AccountVM], codexNames: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                AccountRow(
                    account: account,
                    isSwitching: store.switchingAccount == account.id,
                    name: codexNames ? account.codexColumnName : nil,
                    onSwitch: { store.switchTo(accountNumber: account.id) }
                )
                if index < accounts.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Footer

    /// Soonest resetsAt among ≥90% meters; else the soonest overall.
    private var footerReset: (label: String, accountName: String, resetsAt: Date)? {
        let candidates = store.accounts.flatMap { account in
            account.meters.filter { $0.resetsAt != nil }.map { (meter: $0, account: account) }
        }
        let critical = candidates.filter { $0.meter.pct >= 90 }
        let pool = critical.isEmpty ? candidates : critical
        guard let soonest = pool.min(by: { $0.meter.resetsAt! < $1.meter.resetsAt! }) else { return nil }
        return (soonest.meter.label, soonest.account.displayName, soonest.meter.resetsAt!)
    }

    private var footer: some View {
        Group {
            if let error = store.fetchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.color(for: .serious))
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.color(for: .serious))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            } else if let reset = footerReset {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: 0) {
                        Text("next reset \(reset.label) · \(reset.accountName) · \(Countdown.string(until: reset.resetsAt, now: context.date))")
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }
}
