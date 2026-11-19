// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct PokeDaisyDashboard: View {
    let onClose: () -> Void
    @State private var tab = Tab.party

    private enum Tab: String { case party, route, battle }

    var body: some View {
        let snapshot = EssentialsTelemetryStore.shared.snapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "camera.macro")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(verbatim: "PokeDaisy")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let map = snapshot?.map {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "mappin")
                            if map.name.isEmpty {
                                Text("Map \(map.id)")
                            } else {
                                Text(verbatim: map.name)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close PokeDaisy")
                .accessibilityIdentifier("pokedaisy.close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, Spacing.xl)
            .padding(.trailing, Spacing.xs)
            .padding(.top, Spacing.xs)

            HStack(spacing: Spacing.xs) {
                tabButton(.party, "Party", image: "person.2.fill")
                tabButton(.route, "Route", image: "map")
                tabButton(.battle, "Battle", image: "bolt.shield")
            }
            .padding(.horizontal, Spacing.xs)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)

            ScrollView {
                Group {
                    if let snapshot {
                        switch tab {
                        case .party: PartyTab(members: snapshot.party)
                        case .route: RouteTab(slots: snapshot.encounters)
                        case .battle: BattleTab(battle: snapshot.battle)
                        }
                    } else {
                        PanelMessage(
                            "Game data unavailable", icon: "leaf",
                            detail: "Open a Pokémon Essentials save to see its game data.")
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pokedaisy.dashboard")
    }
    private func tabButton(_ value: Tab, _ title: LocalizedStringResource, image: String) -> some View {
        let active = tab == value
        return Button {
            tab = value
        } label: {
            ViewThatFits(in: .horizontal) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: image)
                }
                Text(title)
            }
            .font(.subheadline.weight(active ? .semibold : .medium))
            .foregroundStyle(active ? Color.brand : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(active ? Color.brand.opacity(0.14) : .clear, in: .rect(cornerRadius: 9))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("pokedaisy.tab." + value.rawValue)
    }

}

private struct PanelMessage: View {
    let title: LocalizedStringResource
    let icon: String
    let detail: LocalizedStringResource?

    init(_ title: LocalizedStringResource, icon: String, detail: LocalizedStringResource? = nil) {
        self.title = title
        self.icon = icon
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(.brand)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// IDs are supplied by the current game. Preserve mixed case and Unicode when
/// a fork supplies its own labels.
private func displayID(_ raw: String) -> String {
    let label = raw.replacingOccurrences(of: "_", with: " ")
    return label == label.uppercased() ? label.capitalized : label
}

private struct TypeLine: View {
    let types: [String]

    var body: some View {
        if !types.isEmpty {
            Text(verbatim: types.map(displayID).joined(separator: " · "))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    Text("Types, \(types.map(displayID).joined(separator: ", "))"))
        }
    }
}

private struct HealthBar: View {
    let fraction: Double

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(fraction > 0.5 ? .success : fraction > 0.2 ? .warning : .destructive)
            .accessibilityHidden(true)
    }
}

private struct PartyTab: View {
    let members: [EssentialsSnapshot.PartyMember]
    @State private var expandedSlot: Int? = 0

    var body: some View {
        if members.isEmpty {
            PanelMessage("No party members", icon: "person.2")
        } else {
            LazyVStack(spacing: Spacing.md) {
                ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Button {
                            expandedSlot = expandedSlot == index ? nil : index
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                    Text(
                                        verbatim: member.nickname.isEmpty
                                            ? displayID(member.species) : member.nickname
                                    )
                                    .font(.headline)
                                    Spacer(minLength: 0)
                                    Text("Lv. \(member.level)")
                                        .font(.caption.bold().monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: expandedSlot == index ? "chevron.up" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if member.nickname.caseInsensitiveCompare(displayID(member.species))
                                    != .orderedSame,
                                    !member.nickname.isEmpty
                                {
                                    Text(verbatim: displayID(member.species)).font(.subheadline)
                                }
                                TypeLine(types: member.types)
                                HStack(spacing: Spacing.sm) {
                                    if let status = member.status {
                                        Text(verbatim: displayID(status))
                                            .font(.caption2.bold())
                                            .foregroundStyle(.warning)
                                            .padding(.horizontal, Spacing.sm).padding(.vertical, 2)
                                            .background(Color.warning.opacity(0.13), in: .capsule)
                                    }
                                    HealthBar(
                                        fraction: member.maxHP > 0
                                            ? Double(member.hp) / Double(member.maxHP) : 0)
                                    Text("\(member.hp)/\(member.maxHP) HP")
                                        .font(.caption.monospacedDigit())
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(expandedSlot == index ? Text("Expanded") : Text("Collapsed"))
                        .accessibilityIdentifier("pokedaisy.party.\(index)")
                        if expandedSlot == index {
                            Divider()
                            LabeledContent {
                                if let item = member.item {
                                    Text(verbatim: member.itemName ?? displayID(item))
                                } else {
                                    Text("None")
                                }
                            } label: {
                                Label("Held item", systemImage: "bag")
                            }
                            .font(.caption)
                            if !member.moves.isEmpty {
                                ForEach(Array(member.moves.enumerated()), id: \.offset) { _, move in
                                    HStack {
                                        Text(verbatim: move.name ?? displayID(move.id))
                                        Spacer(minLength: Spacing.sm)
                                        Text("\(move.pp)/\(move.maxPP) PP")
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    .font(.subheadline)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    .padding(Spacing.lg)
                    .background(.white.opacity(0.065), in: .rect(cornerRadius: 14))
                }
            }
        }
    }
}

private struct RouteTab: View {
    let slots: [EssentialsSnapshot.EncounterSlot]?
    @State private var selectedMethod: String?

    var body: some View {
        if let slots {
            let methods = PokeDaisyEncounterMethod.methods(in: slots)
            if let method = methods.first(where: { $0.id == selectedMethod }) ?? methods.first {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack {
                        Text("Encounter chance").font(.subheadline.bold())
                        Spacer(minLength: Spacing.sm)
                        if methods.count > 1 {
                            Menu {
                                Picker(
                                    "Encounter method",
                                    selection: Binding(
                                        get: { method.id }, set: { selectedMethod = $0 }
                                    )
                                ) {
                                    ForEach(methods) { Text(verbatim: displayID($0.id)).tag($0.id) }
                                }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Text(verbatim: displayID(method.id))
                                    Image(systemName: "chevron.up.chevron.down")
                                }.frame(minHeight: 44)
                            }
                            .font(.subheadline).foregroundStyle(.brand)
                            .accessibilityIdentifier("pokedaisy.encounterMethod")
                        } else {
                            Text(verbatim: displayID(method.id)).font(.subheadline).foregroundStyle(
                                .secondary)
                        }
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(method.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(verbatim: displayID(entry.species)).font(.subheadline.bold())
                                    Text("Lv. \(levelList(entry.levels))").font(.caption).foregroundStyle(
                                        .secondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: Spacing.xs) {
                                    Text(entry.chance, format: .percent.precision(.significantDigits(1...3)))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                    dexStatus(entry).font(.caption)
                                }
                            }
                            .padding(.vertical, Spacing.md)
                            .accessibilityElement(children: .combine)
                            if entry.id != method.entries.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .background(.white.opacity(0.065), in: .rect(cornerRadius: 14))
                }
            } else {
                PanelMessage("No wild encounters here", icon: "leaf")
            }
        } else {
            PanelMessage("Encounter data unavailable", icon: "map")
        }
    }

    private func levelList(_ levels: [ClosedRange<Int>]) -> String {
        levels.map { range in
            let low = range.lowerBound.formatted()
            return range.lowerBound == range.upperBound ? low : low + "–" + range.upperBound.formatted()
        }.joined(separator: ", ")
    }

    @ViewBuilder private func dexStatus(_ entry: PokeDaisyEncounterMethod.Entry) -> some View {
        if entry.caught == true {
            Label("Caught", systemImage: "checkmark.circle.fill").foregroundStyle(.success)
        } else if entry.seen == true {
            Label("Seen", systemImage: "eye").foregroundStyle(.secondary)
        } else if entry.seen == false {
            Label("Unseen", systemImage: "eye.slash").foregroundStyle(.secondary)
        } else if entry.caught == false {
            Text("Uncaught").foregroundStyle(.secondary)
        } else {
            Text("Pokédex unknown").foregroundStyle(.secondary)
        }
    }
}

private struct BattleTab: View {
    let battle: EssentialsSnapshot.Battle?
    @State private var allyIndex: Int?
    @State private var opponentIndex: Int?

    var body: some View {
        if let battle {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                let ally = selected(battle.allies, index: allyIndex)
                let opponent = selected(battle.opponents, index: opponentIndex)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        battlerCard(
                            "Your battler", battlers: battle.allies, current: ally, choice: $allyIndex)
                        battlerCard(
                            "Opponent", battlers: battle.opponents, current: opponent, choice: $opponentIndex)
                    }
                    VStack(spacing: Spacing.md) {
                        battlerCard(
                            "Your battler", battlers: battle.allies, current: ally, choice: $allyIndex)
                        battlerCard(
                            "Opponent", battlers: battle.opponents, current: opponent, choice: $opponentIndex)
                    }
                }
                if let ally, let opponent {
                    Text("Type matchups").font(.headline).accessibilityAddTraits(.isHeader)
                    matchup("Your attacking types", attacker: ally, defender: opponent)
                    matchup("Opponent attacking types", attacker: opponent, defender: ally)
                }
            }
        } else {
            PanelMessage("No active battle", icon: "bolt.shield")
        }
    }

    private func selected(
        _ battlers: [EssentialsSnapshot.Battler], index: Int?
    ) -> EssentialsSnapshot.Battler? {
        battlers.first { $0.index == index } ?? battlers.first { $0.hpPercent > 0 } ?? battlers.first
    }

    private func battlerCard(
        _ title: LocalizedStringResource, battlers: [EssentialsSnapshot.Battler],
        current: EssentialsSnapshot.Battler?, choice: Binding<Int?>
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let current {
                if battlers.count > 1 {
                    Menu {
                        Picker(
                            title,
                            selection: Binding(get: { current.index }, set: { choice.wrappedValue = $0 })
                        ) {
                            ForEach(battlers, id: \.index) { battler in
                                Text("\(displayID(battler.species)) · \(battler.index + 1)").tag(
                                    battler.index)
                            }
                        }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Text(verbatim: displayID(current.species))
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .frame(minHeight: 44)
                    }
                    .font(.subheadline.bold()).foregroundStyle(.brand)
                } else {
                    Text(verbatim: displayID(current.species)).font(.subheadline.bold())
                }
                TypeLine(types: current.types)
                Text("\(current.hpPercent)% HP").font(.caption.monospacedDigit())
                HealthBar(fraction: Double(current.hpPercent) / 100)
                let changed = current.stages.filter { $0.value != 0 }.keys.sorted()
                if !changed.isEmpty {
                    Text(
                        verbatim: changed.map { stat in
                            let stage = current.stages[stat, default: 0].formatted(
                                .number.sign(strategy: .always()))
                            return displayID(stat) + " " + stage
                        }.joined(separator: " · ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Unavailable").font(.subheadline)
            }
        }
        .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(.white.opacity(0.065), in: .rect(cornerRadius: 12))
    }

    private func matchup(
        _ title: LocalizedStringResource, attacker: EssentialsSnapshot.Battler,
        defender: EssentialsSnapshot.Battler
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if attacker.types.isEmpty || defender.incomingEffectiveness == nil {
                Text("Type chart unavailable").font(.subheadline)
            } else {
                ForEach(Array(attacker.types.enumerated()), id: \.offset) { _, type in
                    HStack {
                        Text(verbatim: displayID(type)).font(.subheadline)
                        Spacer(minLength: Spacing.md)
                        if let value = defender.incomingEffectiveness?[type], value.isFinite, value >= 0 {
                            Text(
                                verbatim: value.formatted(.number.precision(.significantDigits(1...5))) + "×"
                            )
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(value > 1 ? Color.success : value < 1 ? .warning : .primary)
                        } else {
                            Text("Unknown").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
