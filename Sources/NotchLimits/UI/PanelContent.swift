import SwiftUI

/// The open-state panel content: token hero, header, account rows, footer.
/// Laid out at its natural intrinsic height (MorphShell owns the height cap
/// and clips to it; Snapshot passes the same list cap). `width`
/// tracks the wrap shape's actual open width (`openWidth(notchWidth:
/// twoColumns:)`), since that varies by machine. `notchHeight` insets all
/// content below the physical notch band (also machine-varying) so nothing
/// ever sits above the cutout — the band beside/around the notch stays pure
/// contentless glass. With Codex rows the list splits in two: Claude on the
/// left, Codex on the right, each under its own half of the header, while
/// the hero and footer keep the full width.
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

    /// One column wraps the notch in about 110pt of glass a side
    /// (DESIGN-V1.1). The Codex column is a second column of exactly that
    /// width, so a row lays out as it does in the single list: three
    /// meters, the big percentage and a full email all fit, nothing
    /// squeezed. 2 × 405 + 12 = 822pt on a 14" MacBook Pro or the
    /// synthetic band.
    static func columnWidth(notchWidth: CGFloat) -> CGFloat { notchWidth + 220 }
    static let columnGap: CGFloat = 12
    static func openWidth(notchWidth: CGFloat, twoColumns: Bool) -> CGFloat {
        let column = columnWidth(notchWidth: notchWidth)
        return twoColumns ? column * 2 + columnGap : column
    }

    private var columnWidth: CGFloat { (width - Self.columnGap) / 2 }

    var body: some View {
        VStack(spacing: 0) {
            TokenHero(tokens: tokens)
            if store.showsCodexColumn {
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

    /// The single header's two halves, one over each column; the controls
    /// stay at the far right.
    private var columnHeaders: some View {
        HStack(spacing: Self.columnGap) {
            HStack(spacing: 8) {
                ClaudeSpark().fill(Ink.coral).frame(width: 16, height: 16)
                Text("Claude")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: columnWidth)

            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                Text("Codex")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ink.primary)

                Spacer(minLength: 8)

                headerControls
            }
            .padding(.horizontal, 16)
            .frame(width: columnWidth)
        }
        .frame(height: Self.headerHeight)
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
        if store.showsCodexColumn {
            HStack(alignment: .top, spacing: Self.columnGap) {
                rowsStack(store.claudeAccounts)
                    .frame(width: columnWidth)
                rowsStack(store.codexAccounts, codexNames: true)
                    .frame(width: columnWidth)
            }
        } else {
            rowsStack(store.accounts)
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
