// The screensaver's own settings sheet: pick a look, see it, keep it.
//
// Built in code rather than from a nib, because `tools/build-saver.sh` compiles Swift sources
// into a bundle and has no Interface Builder step — and a nib would be a binary asset in a repo
// whose rule is that assets are generated from source.
//
// The whole reason it carries a live preview is that "shallow reef" and "deep ocean" are words.
// The three looks differ in light, water colour and substrate — nothing a name conveys — and
// the settings sheet is the one place a user is choosing between them.

import AppKit
import ScreenSaver

final class AquariumSettingsSheet: NSObject {

    /// What the sheet offers, in the order it offers it. The copy lives here rather than on
    /// `TankStyleName` because it is interface, not tank: `TankStyle` is a bag of numbers handed
    /// to code that does not know which style it is, and giving it a display name would be the
    /// first thing to reach past that line.
    private struct Option {
        let preference: StylePreference
        let title: String
        let caption: String
    }

    private static let options: [Option] = [
        Option(preference: .fixed(.shallowReef), title: "Shallow reef",
               caption: "Snorkelling depth. Warm daylight from just overhead, turquoise water, "
                      + "pale sand, and the far reef still legible."),
        Option(preference: .fixed(.deepOcean), title: "Deep ocean",
               caption: "Twenty metres down. Cold blue-white light, dark sand, and haze that "
                      + "takes the reef within a few metres."),
        Option(preference: .fixed(.aquarium), title: "Aquarium",
               caption: "A lit glass tank, seen through the front pane. Fluorescent blue-white "
                      + "from a hood lamp, saturated blue water, crowded with ornaments, and a "
                      + "different colour of gravel every launch."),
        Option(preference: .random, title: "Surprise me",
               caption: "One of the three, drawn fresh every time the screensaver starts."),
    ]

    /// Lower-cased, because it is used mid-sentence under the preview.
    private static func title(of name: TankStyleName) -> String {
        let match = options.first { $0.preference == .fixed(name) }
        return (match?.title ?? name.rawValue).lowercased()
    }

    /// 16:9, and large enough that a fish is a fish rather than a mote. Below the saver's own
    /// 600-point preview threshold, so the preview renders as the System Settings thumbnail
    /// does: `RenderQuality.reduced`, which is the whole tank at a fraction of the pixels.
    private static let previewSize = NSSize(width: 384, height: 216)

    let window: NSWindow

    private let defaults: ScreenSaverDefaults?
    /// The choice the sheet is showing, which is not yet the saved one — Cancel has to be able
    /// to leave no trace, including on the running saver.
    private var pending: AquariumSettings
    private var buttons: [NSButton] = []
    private let seedField = NSTextField()
    private let showSeedButton = NSButton()
    private let soundButton = NSButton()
    private let previewContainer = NSView()
    private var previewView: AquariumView?
    private let previewNote = NSTextField(labelWithString: "")
    /// Which look "Surprise me" shows, click after click. The tank's own launch seed, so that
    /// `run-saver --configure --screenshot` under a pinned `AQUARIUM_SEED` captures the same
    /// sheet twice — the one command that exists to look at this thing should not be the one
    /// thing in the repo that cannot be pinned.
    private var previewRand = Rand(seed: AquariumScene.launchSeed())

    /// The preview's lifetime, tied to the sheet actually being on screen.
    ///
    /// Not merely a tidier place to call `stopAnimation`: the sheet can be dismissed by
    /// something other than its own buttons — the host ends it — and a sheet ended that way
    /// sends its delegate nothing at all. Measured: on `endSheet` the window's `isVisible`
    /// goes false and the KVO fires, while `windowWillClose` and `windowDidEndSheet` do not
    /// arrive. Without this, a host-dismissed sheet leaves a tank rendering at 60 fps inside
    /// System Settings with nothing on screen to show for it.
    private var visibility: NSKeyValueObservation?

    /// Called when the user keeps a change, so the view that opened the sheet can adopt it.
    var onCommit: ((AquariumSettings) -> Void)?

    init(defaults: ScreenSaverDefaults?) {
        self.defaults = defaults
        self.pending = AquariumSettings.load(from: defaults)
        // Provisional: `buildInterface` sizes the window from its own constraints at the end.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // A sheet is dismissed, not closed, and it is presented more than once — the host asks
        // for `configureSheet` on every press of Options. Releasing it on close would hand the
        // host a freed window the second time.
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
        // Belt and braces. `visibility` is what actually stops the preview in every path that
        // has been observed; this only covers a sheet released while still on screen.
        previewView?.stopAnimation()
    }

    // MARK: Presentation

    /// Call immediately before the host presents the sheet.
    ///
    /// The sheet outlives its presentation, so it re-reads the saved settings here rather than
    /// in `init`: a second visit must show what is actually stored, not what the previous visit
    /// left on screen after a Cancel.
    ///
    /// The preview is *not* started here — `rebuildPreview` declines while the window is
    /// hidden, and `visibility` starts it when the sheet actually appears.
    func prepareForPresentation() {
        pending = AquariumSettings.load(from: defaults)
        syncButtons()
        rebuildPreview()
    }

    private func dismiss() {
        stopPreview()
        // Both known hosts present this with `beginSheet`, so `sheetParent` is expected to be
        // there — System Settings, and `tools/run-saver.swift --configure`. The fallback is for
        // a host that shows the window some other way: dismissing the sheet is the only way out
        // of it, and a dismiss button that does nothing would strand the user.
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: Actions

    @objc private func styleChanged(_ sender: NSButton) {
        let index = sender.tag
        guard AquariumSettingsSheet.options.indices.contains(index) else { return }
        pending.style = AquariumSettingsSheet.options[index].preference
        syncButtons()
        rebuildPreview()
    }

    @objc private func seedChanged(_ sender: Any?) {
        readSeedField()
        rebuildPreview()
    }

    @objc private func showSeedChanged(_ sender: NSButton) {
        pending.showsSeed = sender.state == .on
        // No preview rebuild: the thumbnail never draws the badge, so there would be nothing
        // to see and it would cost a whole tank — see `AquariumScene.init`.
    }

    @objc private func soundChanged(_ sender: NSButton) {
        pending.soundEnabled = sender.state == .on
        // No preview rebuild: the setting changes no part of the picture, and the preview is
        // deliberately silent.
    }

    /// Takes whatever is in the field and turns it into a pinned seed, or into none.
    ///
    /// Anything that is not a plain unsigned integer is rejected by putting the last accepted
    /// value back, rather than by an alert: the failure is one keystroke away from being
    /// corrected and the field is a box for a number people are copying off a screen.
    private func readSeedField() {
        let typed = seedField.stringValue.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            pending.seed = nil
        } else if let seed = UInt64(typed) {
            pending.seed = seed
        }
        syncSeedControls()
    }

    @objc private func commit(_ sender: Any?) {
        // Read again rather than trusting the field's action to have fired. Clicking OK ends
        // editing and normally does fire it, but a sheet dismissed by its default key
        // equivalent while the field is first responder is one path where the last thing typed
        // would otherwise be dropped — silently, and into a feature whose entire purpose is
        // getting one exact number out of the user's head and into the tank.
        readSeedField()
        pending.write(to: defaults)
        onCommit?(pending)
        dismiss()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    // MARK: Preview

    /// Which style the preview shows. `.random` has no single answer, so it shows one of the
    /// three — a different one each time the option is picked, which is exactly what the option
    /// means and is more honest than freezing on one of them.
    private func previewStyle() -> TankStyleName {
        switch pending.style {
        case .fixed(let name): return name
        case .random: return TankStyleName.drawn(&previewRand)
        }
    }

    private func rebuildPreview() {
        stopPreview()
        // One rule, in one place: nothing renders unless the sheet is on screen. `configureSheet`
        // is a property, and a host is free to read it and then not present what it got — at
        // which point a preview started eagerly would render forever, because `isVisible` cannot
        // fall from a value it never reached. Measured: the window returned from that getter has
        // `isVisible == false`, so this is the state the sheet is built in, not an edge case.
        guard window.isVisible else { return }

        let showing = previewStyle()
        // "Surprise me" has to say which of the three it landed on, or the preview reads as a
        // fourth look — the aquarium and the reef are recognisable, and a user seeing one of
        // them under "Surprise me" would reasonably conclude the option does nothing.
        previewNote.stringValue = pending.style == .random
            ? "Showing \(AquariumSettingsSheet.title(of: showing)). A different look, and a "
              + "different tank, every launch."
            : "Every launch draws a different tank."

        let frame = NSRect(origin: .zero, size: AquariumSettingsSheet.previewSize)
        guard let view = AquariumView(frame: frame, isPreview: true) else { return }
        // The one instance whose settings do not come from disk: it is showing a choice that
        // has not been made yet, and may never be. It carries the pending seed as well as the
        // pending style, so typing a seed shows the tank it names — and half of the caveat that
        // used to live here is gone: a `.reduced` tank is no longer *trimmed*, so this draws the
        // same thirty props and twenty-two fish the full tank will.
        //
        // The other half stands, for a different reason. This preview is pinned to 16:9 and the
        // display is not, and the reef is laid out against the drawable's aspect — `Tank.propCount`
        // scales with reef capacity and `ReefLayout` places into the frame it is given. So a
        // seed typed here still names that seed's look, gravel and cast rather than these exact
        // positions. The picker's own tile does not have this problem: the resolution cap is one
        // factor on both axes, so it keeps the display's aspect.
        var override = pending
        override.style = .fixed(showing)
        view.settingsOverride = override
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
        for (index, option) in AquariumSettingsSheet.options.enumerated() {
            buttons[index].state = option.preference == pending.style ? .on : .off
        }
        syncSeedControls()
        soundButton.state = pending.soundEnabled ? .on : .off
    }

    private func syncSeedControls() {
        seedField.stringValue = pending.seed.map(String.init) ?? ""
        showSeedButton.state = pending.showsSeed ? .on : .off
    }

    private func buildInterface() {
        guard let content = window.contentView else { return }

        let title = label("Aquarium", font: .systemFont(ofSize: 15, weight: .semibold),
                          colour: .labelColor)
        let subtitle = label("A tank of reef fish, drawn differently every launch.",
                             font: .systemFont(ofSize: 12), colour: .secondaryLabelColor)

        let choices = NSStackView(views: AquariumSettingsSheet.options.enumerated().map {
            optionRow($1, index: $0)
        })
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 12

        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 6
        // Metal renders into a sublayer, so the rounded corner has to clip rather than just
        // draw; without this the tank squares off the box it sits in.
        previewContainer.layer?.masksToBounds = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false

        previewNote.font = .systemFont(ofSize: 11)
        previewNote.textColor = .secondaryLabelColor
        previewNote.lineBreakMode = .byWordWrapping
        previewNote.maximumNumberOfLines = 2
        previewNote.stringValue = "Every launch draws a different tank."

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let okButton = NSButton(title: "OK", target: self, action: #selector(commit(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [cancelButton, okButton])
        actions.orientation = .horizontal
        actions.spacing = 12

        let seed = seedSection()

        for view in [title, subtitle, choices, seed, previewContainer, previewNote, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin: CGFloat = 20
        let preview = AquariumSettingsSheet.previewSize
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            choices.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            choices.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            choices.widthAnchor.constraint(equalToConstant: 260),

            seed.topAnchor.constraint(equalTo: choices.bottomAnchor, constant: 18),
            seed.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            seed.widthAnchor.constraint(equalTo: choices.widthAnchor),

            previewContainer.topAnchor.constraint(equalTo: choices.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: choices.trailingAnchor,
                                                      constant: 24),
            previewContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                       constant: -margin),
            previewContainer.widthAnchor.constraint(equalToConstant: preview.width),
            previewContainer.heightAnchor.constraint(equalToConstant: preview.height),

            previewNote.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
            previewNote.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewNote.widthAnchor.constraint(equalTo: previewContainer.widthAnchor),
            // Two lines' worth, always. The note grows a line when "Surprise me" names the look
            // it is showing, and the window is sized once, at build time — a note that reflowed
            // would push the buttons off the bottom of a sheet that cannot resize to follow.
            previewNote.heightAnchor.constraint(equalToConstant: 30),

            // Whichever column is taller sets the height, so the buttons stay clear of both.
            actions.topAnchor.constraint(greaterThanOrEqualTo: seed.bottomAnchor,
                                         constant: 20),
            actions.topAnchor.constraint(greaterThanOrEqualTo: previewNote.bottomAnchor,
                                         constant: 20),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                              constant: -margin),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        syncButtons()
        window.setContentSize(content.fittingSize)
    }

    /// The seed field and the badge switch, which are one control in two parts.
    ///
    /// They are grouped and captioned together because neither is usable alone: the number to
    /// type into the field can only be learned by reading it off a running tank, and the badge
    /// is only worth showing to somebody who has somewhere to type the number back.
    private func seedSection() -> NSView {
        let heading = label("Seed", font: .systemFont(ofSize: 12, weight: .semibold),
                            colour: .labelColor)

        seedField.placeholderString = "Random"
        seedField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        seedField.alignment = .left
        seedField.target = self
        seedField.action = #selector(seedChanged(_:))
        // Commits on focus loss as well as on Return. Without it a user who types a seed and
        // clicks OK gets the tank they had before, which reads as the field not working.
        seedField.isContinuous = false

        let caption = label("Draws the same tank every time. Leave it empty for a new tank on "
                            + "every launch.",
                            font: .systemFont(ofSize: 11), colour: .secondaryLabelColor)
        caption.preferredMaxLayoutWidth = 240

        showSeedButton.setButtonType(.switch)
        showSeedButton.title = "Show the seed on screen"
        showSeedButton.target = self
        showSeedButton.action = #selector(showSeedChanged(_:))

        soundButton.setButtonType(.switch)
        soundButton.title = "Play tank sounds"
        soundButton.target = self
        soundButton.action = #selector(soundChanged(_:))
        // The preview tank inside this sheet is deliberately silent regardless of this switch,
        // because audio is gated on the screensaver session and never on a view.

        let section = NSView()
        for view in [heading, seedField, caption, showSeedButton, soundButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: section.topAnchor),
            heading.leadingAnchor.constraint(equalTo: section.leadingAnchor),

            seedField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            seedField.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            // Wide enough for the longest thing that can go in it. Launch seeds are six
            // digits, but `AQUARIUM_SEED` accepts any `UInt64` and a render tuned under one
            // has to be reproducible from the sheet too.
            seedField.widthAnchor.constraint(equalToConstant: 170),

            caption.topAnchor.constraint(equalTo: seedField.bottomAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: section.trailingAnchor),

            showSeedButton.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 10),
            showSeedButton.leadingAnchor.constraint(equalTo: section.leadingAnchor),

            soundButton.topAnchor.constraint(equalTo: showSeedButton.bottomAnchor, constant: 8),
            soundButton.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            soundButton.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        return section
    }

    private func optionRow(_ option: Option, index: Int) -> NSView {
        let button = NSButton(radioButtonWithTitle: option.title, target: self,
                              action: #selector(styleChanged(_:)))
        button.tag = index
        buttons.append(button)

        let caption = label(option.caption, font: .systemFont(ofSize: 11),
                            colour: .secondaryLabelColor)
        caption.preferredMaxLayoutWidth = 240

        let row = NSView()
        for view in [button, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            // Indented under the radio's title rather than under its dot, so the caption reads
            // as belonging to the label above it.
            caption.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func label(_ text: String, font: NSFont, colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }
}
