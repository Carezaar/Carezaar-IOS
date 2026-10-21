import SwiftUI

/// Multi-select chips over a base lookup table. Selected ids are submitted as a
/// comma-joined string, which `FormValue.ids` handles.
struct MultiSelectField: View {
    let title: String
    let items: [BaseItem]
    @Binding var selection: [Int]
    var languageId: Int
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Palette.textSecondary)

            if items.isEmpty {
                Text("Nothing to choose yet")
                    .font(Theme.Typography.caption())
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                FlowLayout(spacing: Theme.Spacing.xs) {
                    ForEach(items) { item in
                        let isOn = selection.contains(item.id)
                        Button {
                            if isOn { selection.removeAll { $0 == item.id } }
                            else { selection.append(item.id) }
                        } label: {
                            Text(item.name(languageId: languageId))
                                .font(Theme.Typography.body())
                                .foregroundStyle(isOn ? .white : Theme.Palette.textPrimary)
                                .padding(.horizontal, Theme.Spacing.s)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(isOn ? Theme.Palette.primaryFill : Theme.Palette.clientPanel)
                                .clipShape(Capsule())
                        }
                        .accessibilityAddTraits(isOn ? [.isSelected] : [])
                    }
                }
            }

            if let error {
                Text(error).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.error)
            }
        }
    }
}

/// Single-select menu over a base lookup table.
struct SingleSelectField: View {
    let title: String
    let items: [BaseItem]
    @Binding var selection: Int?
    var languageId: Int
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.body())
                .foregroundStyle(Theme.Palette.textSecondary)
            Picker(title, selection: $selection) {
                Text("Select one").tag(Int?.none)
                ForEach(items) { item in
                    Text(item.name(languageId: languageId)).tag(Int?.some(item.id))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error {
                Text(error).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.error)
            }
        }
    }
}

/// Hourly pay range, shown as `signup_form_client_usd_per_hour`.
struct SalaryRangeField: View {
    @Binding var minimum: Int?
    @Binding var maximum: Int?
    var error: String?
    @EnvironmentObject private var loc: Localization
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("signup_form_client_pay_rate", "Pay Rate")).font(Theme.Typography.title(16))
            HStack(spacing: Theme.Spacing.s) {
                numberField(loc.t("signup_form_client_minimum", "Minimum"), value: $minimum)
                numberField(loc.t("signup_form_client_maximum", "Maximum"), value: $maximum)
            }
            if let error {
                Text(error).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.error)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .shadow(color: Color(red: 16/255, green: 40/255, blue: 80/255).opacity(0.10), radius: 5, y: 2)
        // The number pad has no return key; the screen's bottomAction supplies the
        // keyboard's OK button.
    }

    /// Digits only, written through on every keystroke (a `format:` binding would
    /// only commit when editing ends, losing a value typed just before Continue).
    private func numberField(_ label: String, value: Binding<Int?>) -> some View {
        let text = Binding<String>(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber).prefix(6)) })
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Typography.caption()).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: 6) {
                Text("$").font(Theme.Typography.control()).foregroundStyle(Theme.Palette.textSecondary)
                TextField("0", text: text)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .font(Theme.Typography.control())
                    .accessibilityLabel(label)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: 52)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .stroke(Theme.Palette.separator, lineWidth: 1))
        }
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
