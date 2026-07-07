//
// MeshTopologyView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// Display model for the mesh topology map: nodes are known mesh peers,
/// edges are gossiped `directNeighbors` claims. Built on the main actor from
/// a `MeshTopologySnapshot` plus the current nickname table.
struct MeshTopologyDisplayModel {
    struct Node: Identifiable, Equatable {
        let id: String
        let label: String
        let isSelf: Bool
    }

    let nodes: [Node]
    /// Pairs of `Node.id`; every id is present in `nodes`.
    let edges: [(String, String)]

    static let empty = MeshTopologyDisplayModel(nodes: [], edges: [])
}

/// Minimal diagnostics sheet: the mesh graph on a circular layout (self in
/// the center), drawn with Canvas so it stays cheap at any peer count.
struct MeshTopologyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @ThemedPalette private var palette

    /// Fetches a fresh model; called on appear and on manual refresh.
    let provider: @MainActor () -> MeshTopologyDisplayModel
    @State private var model: MeshTopologyDisplayModel = .empty

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("topology.title")
                    .bitchatFont(size: 16, weight: .bold)
                    .foregroundColor(palette.primary)
                Spacer()
                refreshButton
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(palette.primary)
            }
            .padding()
            .themedSurface(opacity: 0.95)

            content
        }
        .frame(width: 500, height: 520)
        .themedSheetBackground()
        #else
        NavigationView {
            content
                .themedSheetBackground()
                .navigationTitle(Text("topology.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        refreshButton
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        SheetCloseButton { dismiss() }
                            .foregroundColor(palette.primary)
                    }
                }
        }
        #endif
    }

    private var refreshButton: some View {
        Button {
            model = provider()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.bitchatSystem(size: 14))
                .foregroundColor(palette.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("topology.refresh"))
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            if model.nodes.count <= 1 {
                Spacer()
                Text("topology.empty")
                    .bitchatFont(size: 14)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                graphCanvas
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 4) {
                Text(summaryText)
                    .bitchatFont(size: 13, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text("topology.caption")
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .onAppear { model = provider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(summaryText))
    }

    private var summaryText: String {
        String(
            format: String(
                localized: "topology.summary",
                comment: "Topology map summary: number of peers and links"
            ),
            locale: .current,
            model.nodes.count,
            model.edges.count
        )
    }

    private var graphCanvas: some View {
        Canvas { context, size in
            let positions = Self.layout(nodes: model.nodes, in: size)
            let fontDesign = appTheme.bodyFontDesign

            // Edges first so nodes draw on top.
            for (fromID, toID) in model.edges {
                guard let from = positions[fromID], let to = positions[toID] else { continue }
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(palette.secondary.opacity(0.45)), lineWidth: 1)
            }

            for node in model.nodes {
                guard let center = positions[node.id] else { continue }
                let radius: CGFloat = node.isSelf ? 7 : 5
                let dot = Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                context.fill(dot, with: .color(node.isSelf ? palette.accent : palette.primary))
                if node.isSelf {
                    let ring = Path(ellipseIn: CGRect(
                        x: center.x - radius - 3,
                        y: center.y - radius - 3,
                        width: (radius + 3) * 2,
                        height: (radius + 3) * 2
                    ))
                    context.stroke(ring, with: .color(palette.accent.opacity(0.6)), lineWidth: 1)
                }
                context.draw(
                    Text(node.label)
                        .font(.system(size: 10, design: fontDesign))
                        .foregroundColor(node.isSelf ? palette.accent : palette.secondary),
                    at: CGPoint(x: center.x, y: center.y + radius + 4),
                    anchor: .top
                )
            }
        }
        .accessibilityHidden(true) // The combined summary label narrates the graph.
    }

    /// Circular layout: self in the center, everyone else evenly spaced on a
    /// ring. Deterministic (nodes arrive sorted), so refreshes don't shuffle.
    static func layout(nodes: [MeshTopologyDisplayModel.Node], in size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Leave room for the label row under each ring node.
        let radius = max(20, min(size.width, size.height) / 2 - 36)
        var positions: [String: CGPoint] = [:]

        let ringNodes = nodes.filter { !$0.isSelf }
        for node in nodes where node.isSelf {
            positions[node.id] = center
        }
        for (index, node) in ringNodes.enumerated() {
            let angle = (2 * CGFloat.pi * CGFloat(index)) / CGFloat(max(1, ringNodes.count)) - CGFloat.pi / 2
            positions[node.id] = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
        }
        return positions
    }
}

#Preview("Topology") {
    MeshTopologyView(provider: {
        MeshTopologyDisplayModel(
            nodes: [
                .init(id: "self", label: "me", isSelf: true),
                .init(id: "a", label: "alice", isSelf: false),
                .init(id: "b", label: "bob", isSelf: false),
                .init(id: "c", label: "carol", isSelf: false)
            ],
            edges: [("self", "a"), ("a", "b"), ("self", "c")]
        )
    })
}
