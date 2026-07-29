import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    var inputURL: URL?
    var outputURL: URL?
    var status = "Choose a video file to begin"
    var isConverting = false
    var errorMessage: String?

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    func select(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .movie) else {
            errorMessage = "Please choose a video file."
            return
        }
        inputURL = url
        outputURL = nil
        errorMessage = nil
        status = "Ready to make a Discord-friendly MP4"
    }

    func convert() {
        guard let inputURL, !isConverting else { return }
        isConverting = true
        outputURL = nil
        errorMessage = nil

        Task {
            do {
                let output = try await VideoConverter.convert(input: inputURL) { message in
                    Task { @MainActor in self.status = message }
                }
                outputURL = output
                status = "Ready for Discord"
            } catch {
                errorMessage = error.localizedDescription
                status = "Conversion failed"
            }
            isConverting = false
        }
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: model.outputURL == nil ? "arrow.down.doc" : "checkmark.circle.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(model.outputURL == nil ? Color.accentColor : .green)

            VStack(spacing: 6) {
                Text("Vid to Discord")
                    .font(.title2.weight(.semibold))
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let inputURL = model.inputURL {
                Label(inputURL.lastPathComponent, systemImage: "film")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 330)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }

            if model.isConverting {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }

            HStack {
                Button(model.inputURL == nil ? "Choose Video" : "Choose Another") {
                    model.chooseFile()
                }

                if model.outputURL == nil {
                    Button("Convert") {
                        model.convert()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.inputURL == nil || model.isConverting)
                } else if let outputURL = model.outputURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(width: 430)
        .frame(minHeight: 330)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.select(url) }
            }
            return true
        }
    }
}
