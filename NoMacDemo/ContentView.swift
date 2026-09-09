import SwiftUI

struct ContentView: View {
    @State private var tapCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "apple.logo")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("NoMac Demo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Built in the cloud — no Mac required.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                tapCount += 1
            } label: {
                Text("Taps: \(tapCount)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
