import AVFoundation
import Foundation

struct ScenePlayerItem: Identifiable {
    var id: Int { sceneNumber }
    var sceneNumber: Int
    var sceneTitle: String
    var audioURL: URL
    var cueMap: SceneCueMap?
}

@MainActor
final class PlayerState: ObservableObject {

    // MARK: - Published state

    @Published var scenes: [ScenePlayerItem] = []
    @Published var currentSceneIndex: Int = 0
    @Published var cues: [SceneCue] = []
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var currentCueIndex: Int = -1

    @Published var myRole: String = ""
    @Published var muteMyLines: Bool = false
    @Published var blockMyLines: Bool = false
    @Published var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    // MARK: - Setup

    func load(from appState: AppState) {
        guard let pdf = appState.selectedPDF else { return }
        let outDir = appState.outputDirectory ?? appState.defaultOutputDirectory(for: pdf)
        var items: [ScenePlayerItem] = []
        for (number, info) in appState.sceneFileInfo.sorted(by: { $0.key < $1.key }) {
            guard info.exists else { continue }
            let audioURL = outDir.appendingPathComponent(info.filename)
            let cueMap = appState.sceneCueFiles[number].flatMap { Self.loadCueMap(from: $0) }
            items.append(ScenePlayerItem(
                sceneNumber: number,
                sceneTitle: info.title,
                audioURL: audioURL,
                cueMap: cueMap
            ))
        }

        let hadScenes = !scenes.isEmpty
        // Capture the scene number playing before we swap the list
        let currentNumber = scenes.indices.contains(currentSceneIndex)
            ? scenes[currentSceneIndex].sceneNumber : nil

        scenes = items
        guard !scenes.isEmpty else { return }

        if !hadScenes {
            // First load — start at scene 0
            switchToScene(0, autoPlay: false)
        } else if let num = currentNumber,
                  let idx = scenes.firstIndex(where: { $0.sceneNumber == num }) {
            // Preserve active playback: just keep currentSceneIndex aligned.
            // If cues weren't loaded yet (cue file just appeared), pull them in now.
            currentSceneIndex = idx
            if cues.isEmpty, let newCues = scenes[idx].cueMap?.cues, !newCues.isEmpty {
                cues = newCues
            }
        } else {
            // Current scene no longer in the list — fall back to scene 0
            switchToScene(0, autoPlay: false)
        }
    }

    private static func loadCueMap(from url: URL) -> SceneCueMap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SceneCueMap.self, from: data)
    }

    // MARK: - Scene switching

    func switchToScene(_ index: Int, autoPlay: Bool = false) {
        guard index >= 0, index < scenes.count else { return }
        let wasPlaying = isPlaying
        stopTimer()
        player?.stop()
        player = nil
        currentSceneIndex = index
        currentCueIndex = -1
        currentTime = 0
        cues = scenes[index].cueMap?.cues ?? []

        if let p = try? AVAudioPlayer(contentsOf: scenes[index].audioURL) {
            p.enableRate = true
            p.prepareToPlay()
            player = p
        }

        if wasPlaying || autoPlay { play() }
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        p.play()
        p.rate = playbackRate
        isPlaying = true
        startTimer()
    }

    func setRate(_ rate: Float) {
        let snapped = (rate * 20).rounded() / 20  // snap to 0.05 increments
        playbackRate = max(0.5, min(2.0, snapped))
        player?.rate = playbackRate
    }

    func stepRate(by delta: Float) {
        setRate(playbackRate + delta)
    }

    func pause() {
        player?.pause()
        player?.volume = 1  // restore in case we paused mid-muted-line
        isPlaying = false
        stopTimer()
    }

    func nextLine() {
        let next = currentCueIndex + 1
        if next < cues.count { seek(to: cues[next].startTime) }
    }

    func prevLine() {
        guard !cues.isEmpty else { return }
        if currentCueIndex > 0 {
            let cue = cues[currentCueIndex]
            // Restart current cue if we're more than 1.5 s in; else go to previous
            seek(to: currentTime - cue.startTime > 1.5 ? cue.startTime : cues[currentCueIndex - 1].startTime)
        } else {
            seek(to: 0)
        }
    }

    func nextScene() {
        if currentSceneIndex + 1 < scenes.count {
            switchToScene(currentSceneIndex + 1, autoPlay: isPlaying)
        }
    }

    func prevScene() {
        if currentSceneIndex > 0 {
            switchToScene(currentSceneIndex - 1, autoPlay: isPlaying)
        } else {
            seek(to: 0)
        }
    }

    private func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
        updateCurrentCue()
    }

    // MARK: - Timer / tick

    private func startTimer() {
        stopTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func stopTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        updateCurrentCue()

        // Mute my lines: silence the player during my cues so the timing gap is
        // preserved (actor hears silence for the full line duration, aiding memorization).
        // We also look one tick ahead (~0.06 s) so volume drops before the cue's
        // audio starts, eliminating the flicker caused by the 50 ms tick interval.
        let inMutedCue: Bool = {
            guard muteMyLines, !myRole.isEmpty else { return false }
            // Inside a muted cue?
            if currentCueIndex >= 0 {
                let cue = cues[currentCueIndex]
                if isMyLine(cue) && currentTime >= cue.startTime && currentTime < cue.endTime {
                    return true
                }
            }
            // Next cue is a muted line starting within one tick — pre-mute now
            let nextIdx = currentCueIndex + 1
            if nextIdx >= 0, nextIdx < cues.count {
                let next = cues[nextIdx]
                if isMyLine(next) && next.startTime - currentTime <= 0.06 {
                    return true
                }
            }
            return false
        }()
        p.volume = inMutedCue ? 0 : 1

        // Auto-advance to next scene when playback ends
        if !p.isPlaying && isPlaying {
            if currentSceneIndex + 1 < scenes.count {
                switchToScene(currentSceneIndex + 1, autoPlay: true)
            } else {
                pause()
            }
        }
    }

    private func updateCurrentCue() {
        guard !cues.isEmpty else { currentCueIndex = -1; return }
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if c.startTime <= currentTime && currentTime < c.endTime {
                found = mid; break
            } else if c.endTime <= currentTime {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if found == -1 {
            found = cues.lastIndex(where: { $0.startTime <= currentTime }) ?? -1
        }
        currentCueIndex = found
    }

    func isMyLine(_ cue: SceneCue) -> Bool {
        guard !myRole.isEmpty else { return false }
        return cue.speaker.components(separatedBy: "/").contains(myRole)
    }
}
