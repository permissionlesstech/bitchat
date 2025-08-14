import SwiftUI

struct GroupCreationView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var groupName = ""
    @State private var groupDescription = ""
    @State private var isPrivate = false
    @State private var selectedPeers: Set<String> = []
    @State private var showPeerSelection = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Group Details") {
                    TextField("Group Name", text: $groupName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Description (Optional)", text: $groupDescription)
                        .textFieldStyle(.roundedBorder)
                    
                    Toggle("Private Group", isOn: $isPrivate)
                }
                
                Section("Members") {
                    HStack {
                        Text("Selected: \(selectedPeers.count)")
                        Spacer()
                        Button("Add Members") {
                            showPeerSelection = true
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if !selectedPeers.isEmpty {
                        ForEach(Array(selectedPeers), id: \.self) { peerID in
                            HStack {
                                Text(getPeerNickname(peerID))
                                Spacer()
                                Button("Remove") {
                                    selectedPeers.remove(peerID)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                
                Section {
                    Button("Create Group") {
                        createGroup()
                    }
                    .disabled(groupName.isEmpty)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showPeerSelection) {
            PeerSelectionView(selectedPeers: $selectedPeers, viewModel: viewModel)
        }
    }
    
    private func getPeerNickname(_ peerID: String) -> String {
        return viewModel.allPeers.first { $0.id == peerID }?.displayName ?? "Unknown"
    }
    
    private func createGroup() {
        viewModel.createGroup(
            name: groupName,
            initialMembers: selectedPeers,
            isPrivate: isPrivate,
            description: groupDescription.isEmpty ? nil : groupDescription
        )
        dismiss()
    }
}

struct PeerSelectionView: View {
    @Binding var selectedPeers: Set<String>
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.allPeers.filter { !$0.isMe }) { peer in
                    HStack {
                        Text(peer.displayName)
                        Spacer()
                        if selectedPeers.contains(peer.id) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedPeers.contains(peer.id) {
                            selectedPeers.remove(peer.id)
                        } else {
                            selectedPeers.insert(peer.id)
                        }
                    }
                }
            }
            .navigationTitle("Select Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
