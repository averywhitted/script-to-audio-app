import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var playerState: PlayerState

    private var allCharacters: [String] {
        (state.script?.characters.map(\.name) ?? []).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if playerState.scenes.isEmpty {
                noScenesPlaceholder
            } else {
                lyricsArea
                Divider()
                practiceRow
                Divider()
                transport
            }
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { state.isShowingPlayer = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close player")

            if !playerState.scenes.isEmpty {
                Picker("Scene", selection: Binding(
                    get: { playerState.currentSceneIndex },
                    set: { playerState.switchToScene($0) }
                )) {
                    ForEach(Array(playerState.scenes.enumerated()), id: \.element.id) { idx, scene in
                        Text("Scene \(scene.sceneNumber): \(scene.sceneTitle)").tag(idx)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            Spacer()

            if !allCharacters.isEmpty {
                HStack(spacing: 6) {
                    Text("My Role:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("My Role", selection: $playerState.myRole) {
                        Text("Spectator").tag("")
                        Divider()
                        ForEach(allCharacters, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Lyrics scroll area

    private var lyricsArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if playerState.cues.isEmpty {
                        noCueMapPlaceholder
                    } else {
                        ForEach(playerState.cues) { cue in
                            CueRow(
                                cue: cue,
                                isCurrent: playerState.currentCueIndex == cue.index,
                                isMyLine: playerState.isMyLine(cue),
                                blockMyLines: playerState.blockMyLines
                            )
                            .id(cue.index)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: playerState.currentCueIndex) { _, idx in
                guard idx >= 0 else { return }
                withAnimation(.spring(response: 0.3)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Practice toggles

    private var practiceRow: some View {
        HStack(spacing: 24) {
            Spacer()
            Toggle("Mute My Lines", isOn: $playerState.muteMyLines)
                .disabled(playerState.myRole.isEmpty)
                .help(playerState.myRole.isEmpty
                    ? "Select a role above to enable this"
                    : "Skip audio playback for your character's lines")
            Toggle("Block My Lines", isOn: $playerState.blockMyLines)
                .disabled(playerState.myRole.isEmpty)
                .help(playerState.myRole.isEmpty
                    ? "Select a role above to enable this"
                    : "Replace your lines with dots for memorization practice")
            Spacer()
        }
        .font(.callout)
        .padding(.vertical, 10)
    }

    // MARK: - Transport controls

    private var transport: some View {
        HStack(spacing: 28) {
            Button { playerState.prevScene() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playerState.currentSceneIndex == 0 ? Color.secondary : Color.primary)
            .disabled(playerState.currentSceneIndex == 0)
            .help("Previous scene")

            Button { playerState.prevLine() } label: {
                Image(systemName: "arrow.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Previous line")

            Button { playerState.togglePlayPause() } label: {
                Image(systemName: playerState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(playerState.isPlaying ? "Pause" : "Play")

            Button { playerState.nextLine() } label: {
                Image(systemName: "arrow.right")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Next line")

            Button { playerState.nextScene() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(playerState.currentSceneIndex >= playerState.scenes.count - 1
                ? Color.secondary : Color.primary)
            .disabled(playerState.currentSceneIndex >= playerState.scenes.count - 1)
            .help("Next scene")
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Empty state placeholders

    private var noScenesPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No rendered scenes")
                .font(.title3.weight(.semibold))
            Text("Render at least one scene in the Generate step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noCueMapPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No lyrics sync for this scene")
                .font(.headline)
            Text("Re-render the scene to enable line-by-line sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Cue row

private struct CueRow: View {
    let cue: SceneCue
    let isCurrent: Bool
    let isMyLine: Bool
    let blockMyLines: Bool

    private var displayText: String {
        blockMyLines && isMyLine ? "● ● ● ●" : cue.text
    }

    private var speakerLabel: String {
        cue.speaker == "__NARRATOR__"
            ? "Narrator"
            : cue.speaker.replacingOccurrences(of: "/", with: " & ")
    }

    private var accent: Color { speakerColor(cue.speaker) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar for dialog lines
            Rectangle()
                .fill(cue.kind == "dialog" ? accent : Color.clear)
                .frame(width: 3)
                .cornerRadius(1.5)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                if cue.kind == "dialog" {
                    Text(speakerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
                Text(displayText)
                    .font(cue.kind == "dialog" ? .body : .callout.italic())
                    .foregroundStyle(
                        isCurrent
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(cue.kind == "dialog"
                                ? AnyShapeStyle(Color.primary.opacity(0.55))
                                : AnyShapeStyle(Color.secondary))
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Spacer()
        }
        .background(
            isCurrent
                ? (isMyLine
                    ? Color.accentColor.opacity(0.1)
                    : Color.primary.opacity(0.05))
                : Color.clear
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isCurrent)
    }
}
