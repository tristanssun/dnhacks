import SwiftUI

struct ContentView: View {
  @EnvironmentObject var interactionManager: InteractionManager

  @State var textFieldValue = ""
  @State var distance: Float = 0.0

  var body: some View {
    VStack {
      Picker("Ranging", selection: self.$interactionManager.mode) {
        ForEach(DistanceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.top)
      Text(
        self.interactionManager.myTokenId == 0
          ? "Please get your code"
          : String(format: "Your code: %04d", self.interactionManager.myTokenId)
      )
      .font(.title)
      .padding()
      Button(action: {
        self.interactionManager.getMyToken()
      }) {
        Text(
          self.interactionManager.myTokenId == 0
            ? "Get my code"
            : "Refresh my code"
        )
        .padding()
      }
      Text("Peer code")
        .font(.title)
        .padding()
      TextField("Please set the peer code", text: $textFieldValue)
        .keyboardType(.numberPad)
        .onChange(of: textFieldValue) { newValue in
          let digits = String(newValue.filter(\.isNumber).prefix(4))
          if digits != newValue {
            self.textFieldValue = digits
            return
          }

          guard let id = Int(digits), digits.count == 4 else {
            return
          }
          self.hideKeyboard()
          self.interactionManager.getPeerToken(id: id)
        }
        .padding()
      Button(action: {
        self.interactionManager.run(peerId: Int(self.textFieldValue))
      }) {
        Text("Start")
          .padding()
      }
      Text(String(format: "Distance: %.1f m", self.distance))
        .padding(.top)
      Text(self.interactionManager.distanceCaption)
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.bottom)
      if self.interactionManager.mode == .uwb {
        TextField("Server URL", text: self.$interactionManager.apiURL)
          .textInputAutocapitalization(.never)
          .disableAutocorrection(true)
          .keyboardType(.URL)
          .font(.footnote)
          .padding(.horizontal)
      }
      Text(self.interactionManager.statusMessage)
        .font(.footnote)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding()
    }
    .onReceive(self.interactionManager.distance) { distanceValue in
      let before = String(format: "%.1f", self.distance)
      let after = String(format: "%.1f", distanceValue)

      if before != after {
        UIAccessibility.post(notification: .announcement, argument: after)
      }

      self.distance = distanceValue
    }
    .onChange(of: self.interactionManager.mode) { _ in
      self.distance = 0
    }
  }
  func hideKeyboard() {
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { timer in
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
  }
}

struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView()
      .environmentObject(InteractionManager())
  }
}
