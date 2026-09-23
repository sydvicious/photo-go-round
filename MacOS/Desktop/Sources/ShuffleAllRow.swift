import PhotosGoRoundDisplay
import SwiftUI

/// One *Shuffle All* row, drawn like System Settings' screen saver pane: the
/// title on the left, the choice and its chevrons on the right. Syd,
/// 2026-09-14: "The title should be "Shuffle All"", and "don't put in that
/// second line."
///
/// The Settings window's Screensaver and Wallpaper panels use it, and so does
/// a window's Window Settings sheet. **A choice applies as soon as it is made**,
/// with no spinner, because nothing here goes to the agent.
struct ShuffleAllRow: View {
    @Binding var selection: ShuffleInterval

    var body: some View {
        HStack {
            Text("Shuffle All")
            Spacer(minLength: 12)
            Picker("Shuffle All", selection: $selection) {
                ForEach(ShuffleInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
