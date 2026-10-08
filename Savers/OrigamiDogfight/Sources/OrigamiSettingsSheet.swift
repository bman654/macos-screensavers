// The screensaver's settings sheet: what kind of fight, how crowded, whether tanks join in,
// whether the score is kept, and the season and hour it is fought in — in words, with a live
// preview of the choice.
//
// Built in code like the Aquarium's (`AquariumSettingsSheet`), and on the same rules, each of
// which was learned the hard way (`docs/saver-host.md` §2, "The settings sheet is a second
// view"): the window is retained and never released on close; the stored settings are re-read
// on every presentation; nothing renders before the sheet is on screen; and the preview's life
// is tied to KVO on the window's `isVisible`, the one signal an ended sheet sends.

import AppKit
import ScreenSaver

final class OrigamiSettingsSheet: NSObject {

    private struct Choice<Value> {
        let value: Value
        let title: String
    }

    private static let teams: [Choice<TeamsChoice>] = [
        Choice(value: .ffa, title: "Free-for-all"),
        Choice(value: .teams, title: "Teams"),
        Choice(value: .surprise, title: "Surprise me"),
    ]
    private static let planes: [Choice<PlanesChoice>] = [
        Choice(value: .few, title: "A few"),
        Choice(value: .some, title: "Some"),
        Choice(value: .lots, title: "Lots"),
        Choice(value: .surprise, title: "Surprise me"),
    ]
    private static let tanks: [Choice<TanksChoice>] = [
        Choice(value: .off, title: "Off"),
        Choice(value: .sometimes, title: "Sometimes"),
        Choice(value: .always, title: "Always"),
    ]
    private static let seasons: [Choice<SeasonChoice>] = [
        Choice(value: .summer, title: "Summer"),
        Choice(value: .autumn, title: "Autumn"),
        Choice(value: .winter, title: "Winter"),
        Choice(value: .surprise, title: "Surprise me"),
    ]
    private static let dayTimes: [Choice<DayTimeChoice>] = [
        Choice(value: .morning, title: "Morning"),
        Choice(value: .midday, title: "Midday"),
        Choice(value: .evening, title: "Evening"),
        Choice(value: .night, title: "Night"),
        Choice(value: .surprise, title: "Surprise me"),
    ]

    /// 16:9 and under the saver's 600-point preview threshold, so the preview renders as the
    /// System Settings thumbnail does — `RenderQuality.reduced`, the whole fight at a fraction of
    /// the pixels.
    private static let previewSize = NSSize(width: 384, height: 216)
    /// The choices' column: wide enough for four choices in a row with "Surprise me" among
    /// them — at 330 the season's and the hour's first titles were cut to "Sum…" and "Mor…".
    private static let columnWidth: CGFloat = 380
    /// Opens on a fight already going rather than on planes still coming on.
    private static let previewWarmup: Double = 9

    let window: NSWindow

    private let defaults: ScreenSaverDefaults?
    /// The choice the sheet is showing, which is not yet the saved one — Cancel has to be able
    /// to leave no trace, including on the running saver.
    private var pending: OrigamiSettings
    private var teamButtons: [NSButton] = []
    private var planeButtons: [NSButton] = []
    private var tankButtons: [NSButton] = []
    private var seasonButtons: [NSButton] = []
    private var dayTimeButtons: [NSButton] = []
    private let scoreboardButton = NSButton()
    private let previewContainer = NSView()
    private var previewView: OrigamiDogfightView?
    private let previewNote = NSTextField(labelWithString: "")

    /// The preview's lifetime, tied to the sheet actually being on screen. An ended sheet sends
    /// its delegate neither `windowWillClose` nor `windowDidEndSheet`; `isVisible` going false
    /// is all there is, and without this a host-dismissed sheet leaves a fight rendering at
    /// 60 fps inside System Settings with nothing on screen.
    private var visibility: NSKeyValueObservation?

    /// Called when the user keeps a change, so the view that opened the sheet can adopt it.
    var onCommit: ((OrigamiSettings) -> Void)?

    init(defaults: ScreenSaverDefaults?) {
        self.defaults = defaults
        pending = OrigamiSettings.load(from: defaults)
        // Provisional: `buildInterface` sizes the window from its own constraints at the end.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // Presented more than once — the host asks for `configureSheet` on every press of
        // Options — so releasing it on close would hand the host a freed window the second time.
        window.isReleasedWhenClosed = false
        super.init()
        buildInterface()
        visibility = window.observe(\.isVisible) { [weak self] window, _ in
            guard let self else { return }
            if window.isVisible {
                if previewView == nil { rebuildPreview() }
            } else {
                stopPreview()
            }
        }
    }

    deinit {
        // `visibility` stops the preview in every path observed; this covers a sheet released
        // while still on screen.
        previewView?.stopAnimation()
    }

    // MARK: Presentation

    /// Call immediately before the host presents the sheet. Re-reads what is stored, so a
    /// second visit shows that and not what a cancelled first one left on screen. The preview
    /// is not started here: `rebuildPreview` declines while the window is hidden, and
    /// `visibility` starts it when the sheet appears.
    func prepareForPresentation() {
        pending = OrigamiSettings.load(from: defaults)
        syncButtons()
        rebuildPreview()
    }

    private func dismiss() {
        stopPreview()
        // Both known hosts present this with `beginSheet`; the fallback is for one that shows it
        // some other way, where a dismiss button that did nothing would strand the user.
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: Actions

    @objc private func teamsChanged(_ sender: NSButton) {
        guard OrigamiSettingsSheet.teams.indices.contains(sender.tag) else { return }
        pending.teams = OrigamiSettingsSheet.teams[sender.tag].value
        syncButtons()
        rebuildPreview()
    }

    @objc private func planesChanged(_ sender: NSButton) {
        guard OrigamiSettingsSheet.planes.indices.contains(sender.tag) else { return }
        pending.planes = OrigamiSettingsSheet.planes[sender.tag].value
        syncButtons()
        rebuildPreview()
    }

    @objc private func tanksChanged(_ sender: NSButton) {
        guard OrigamiSettingsSheet.tanks.indices.contains(sender.tag) else { return }
        pending.tanks = OrigamiSettingsSheet.tanks[sender.tag].value
        syncButtons()
        rebuildPreview()
    }

    @objc private func seasonChanged(_ sender: NSButton) {
        guard OrigamiSettingsSheet.seasons.indices.contains(sender.tag) else { return }
        pending.season = OrigamiSettingsSheet.seasons[sender.tag].value
        syncButtons()
        rebuildPreview()
    }

    @objc private func dayTimeChanged(_ sender: NSButton) {
        guard OrigamiSettingsSheet.dayTimes.indices.contains(sender.tag) else { return }
        pending.dayTime = OrigamiSettingsSheet.dayTimes[sender.tag].value
        syncButtons()
        rebuildPreview()
    }

    @objc private func scoreboardChanged(_ sender: NSButton) {
        pending.showsScoreboard = sender.state == .on
        rebuildPreview()
    }

    @objc private func commit(_ sender: Any?) {
        pending.write(to: defaults)
        onCommit?(pending)
        dismiss()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    // MARK: Preview

    private func rebuildPreview() {
        stopPreview()
        // One rule, in one place: nothing renders unless the sheet is on screen. The window the
        // `configureSheet` getter hands back has `isVisible == false`, and a host may present
        // nothing at all — a preview started then would never stop.
        guard window.isVisible else { return }

        let surprises = pending.teams == .surprise || pending.planes == .surprise
            || pending.season == .surprise || pending.dayTime == .surprise
        previewNote.stringValue = surprises
            ? "\"Surprise me\" draws afresh, so the preview is one of many."
            : "Every launch draws a different landscape."

        let frame = NSRect(origin: .zero, size: OrigamiSettingsSheet.previewSize)
        guard let view = OrigamiDogfightView(frame: frame, isPreview: true) else { return }
        // The one instance whose settings do not come from disk: it shows a choice that has not
        // been made yet, and may never be.
        view.settingsOverride = pending
        view.previewWarmup = OrigamiSettingsSheet.previewWarmup
        view.autoresizingMask = [.width, .height]
        previewContainer.addSubview(view)
        view.startAnimation()
        previewView = view
    }

    private func stopPreview() {
        previewView?.stopAnimation()
        previewView?.removeFromSuperview()
        previewView = nil
    }

    // MARK: Interface

    private func syncButtons() {
        for (index, choice) in OrigamiSettingsSheet.teams.enumerated() {
            teamButtons[index].state = choice.value == pending.teams ? .on : .off
        }
        for (index, choice) in OrigamiSettingsSheet.planes.enumerated() {
            planeButtons[index].state = choice.value == pending.planes ? .on : .off
        }
        for (index, choice) in OrigamiSettingsSheet.tanks.enumerated() {
            tankButtons[index].state = choice.value == pending.tanks ? .on : .off
        }
        for (index, choice) in OrigamiSettingsSheet.seasons.enumerated() {
            seasonButtons[index].state = choice.value == pending.season ? .on : .off
        }
        for (index, choice) in OrigamiSettingsSheet.dayTimes.enumerated() {
            dayTimeButtons[index].state = choice.value == pending.dayTime ? .on : .off
        }
        scoreboardButton.state = pending.showsScoreboard ? .on : .off
    }

    private func buildInterface() {
        guard let content = window.contentView else { return }

        let title = label("Origami Dogfight", font: .systemFont(ofSize: 15, weight: .semibold), colour: .labelColor)
        let subtitle = label("Paper planes fight over a folded-paper landscape.",
                             font: .systemFont(ofSize: 12), colour: .secondaryLabelColor)

        teamButtons = OrigamiSettingsSheet.teams.enumerated().map { radio($1.title, tag: $0, action: #selector(teamsChanged(_:))) }
        planeButtons = OrigamiSettingsSheet.planes.enumerated().map { radio($1.title, tag: $0, action: #selector(planesChanged(_:))) }
        tankButtons = OrigamiSettingsSheet.tanks.enumerated().map { radio($1.title, tag: $0, action: #selector(tanksChanged(_:))) }
        seasonButtons = OrigamiSettingsSheet.seasons.enumerated().map { radio($1.title, tag: $0, action: #selector(seasonChanged(_:))) }
        dayTimeButtons = OrigamiSettingsSheet.dayTimes.enumerated().map { radio($1.title, tag: $0, action: #selector(dayTimeChanged(_:))) }

        scoreboardButton.setButtonType(.switch)
        scoreboardButton.title = "Keep score on a card in the corner"
        scoreboardButton.target = self
        scoreboardButton.action = #selector(scoreboardChanged(_:))

        let groups = NSStackView(views: [
            group("Teams", teamButtons, caption: "Every plane for itself, or two or three sides."),
            group("Planes", planeButtons, caption: "More planes fly smaller, so the sky stays busy, not crowded."),
            group("Tanks", tankButtons, caption: "Paper tanks on the ground that throw pencils at the planes."),
            group("Season", seasonButtons, caption: "Green fields, autumn gold, or snow with the lakes frozen over."),
            group("Time of day", dayTimeButtons, caption: "Where the day starts. It drifts slowly on toward evening and night."),
            scoreboardButton,
        ])
        groups.orientation = .vertical
        groups.alignment = .leading
        groups.spacing = 16

        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 6
        // Metal renders into a sublayer, so the rounded corner has to clip rather than just draw.
        previewContainer.layer?.masksToBounds = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor

        previewNote.font = .systemFont(ofSize: 11)
        previewNote.textColor = .secondaryLabelColor
        previewNote.lineBreakMode = .byWordWrapping
        previewNote.maximumNumberOfLines = 2

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let okButton = NSButton(title: "OK", target: self, action: #selector(commit(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancelButton, okButton])
        actions.orientation = .horizontal
        actions.spacing = 12

        for view in [title, subtitle, groups, previewContainer, previewNote, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let margin: CGFloat = 20
        let preview = OrigamiSettingsSheet.previewSize
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            groups.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            groups.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            groups.widthAnchor.constraint(equalToConstant: OrigamiSettingsSheet.columnWidth),

            previewContainer.topAnchor.constraint(equalTo: groups.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: groups.trailingAnchor, constant: 24),
            previewContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            previewContainer.widthAnchor.constraint(equalToConstant: preview.width),
            previewContainer.heightAnchor.constraint(equalToConstant: preview.height),

            previewNote.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
            previewNote.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewNote.widthAnchor.constraint(equalTo: previewContainer.widthAnchor),
            // Two lines' worth always: the window is sized once, and a note that reflowed would
            // push the buttons off a sheet that cannot resize to follow.
            previewNote.heightAnchor.constraint(equalToConstant: 30),

            actions.topAnchor.constraint(greaterThanOrEqualTo: groups.bottomAnchor, constant: 20),
            actions.topAnchor.constraint(greaterThanOrEqualTo: previewNote.bottomAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        syncButtons()
        window.setContentSize(content.fittingSize)
    }

    /// A heading, its choices in a row, and a line saying what it does.
    private func group(_ heading: String, _ buttons: [NSButton], caption: String) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 14
        let stack = NSStackView(views: [
            label(heading, font: .systemFont(ofSize: 12, weight: .semibold), colour: .labelColor),
            row,
            label(caption, font: .systemFont(ofSize: 11), colour: .secondaryLabelColor),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func radio(_ title: String, tag: Int, action: Selector) -> NSButton {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: action)
        button.tag = tag
        return button
    }

    private func label(_ text: String, font: NSFont, colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = OrigamiSettingsSheet.columnWidth
        return field
    }
}
