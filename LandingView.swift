import SwiftUI

struct LandingView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("SellMate")
                    .font(.largeTitle).bold()
                    .padding(.top, 16)

                Text("What would you like to do?")
                    .font(.headline)
                    .foregroundColor(.secondary)

                NavigationLink {
                    // Existing reader UI
                    ContentView()
                } label: {
                    Label("Connect to Reader", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                NavigationLink {
                    // Placeholder for now; we’ll implement the editor next
                    PlanogramView()
                } label: {
                    Label("Update Planogram", systemImage: "square.grid.3x3.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
            .navigationTitle("Landing")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

#Preview {
    LandingView()
}
