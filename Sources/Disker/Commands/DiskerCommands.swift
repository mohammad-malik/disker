import SwiftUI

/// Menu bar commands.
///
/// A Mac app without a menu bar is broken, and every action reachable by pointer needs a
/// keyboard equivalent — the menu bar is where users look first for a command they cannot find.
struct DiskerCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        // Disker has no documents, so the stock New/Open items would be dead weight.
        CommandGroup(replacing: .newItem) {}

        // Driven explicitly off the model's UndoManager. SwiftUI's default Undo item follows
        // the responder chain, which never reaches a deletion performed by the model, so
        // Cmd+Z would appear present but do nothing.
        CommandGroup(replacing: .undoRedo) {
            Button(
                model.undoManager.canUndo
                    ? "Undo \(model.undoManager.undoActionName)" : "Undo"
            ) {
                model.undoManager.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.undoManager.canUndo)

            Button(
                model.undoManager.canRedo
                    ? "Redo \(model.undoManager.redoActionName)" : "Redo"
            ) {
                model.undoManager.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.undoManager.canRedo)
        }

        CommandMenu("Scan") {
            Button("Re-scan Volume") {
                Task {
                    await model.scan()
                    await model.loadMoleReport()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Check Mole for Cleanup") {
                Task { await model.loadMoleReport() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Button("Clean with Mole…") {
                model.launchMoleCleanup()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.moleReport == nil)
        }

        CommandMenu("Navigate") {
            Button("Go Up") {
                model.drillUp(to: max(0, model.drillPath.count - 2))
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.drillPath.count <= 1)

            Button("Back to Root") {
                model.drillUp(to: 0)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(model.drillPath.count <= 1)

            Divider()

            Button("Reveal in Finder") {
                if let segment = model.selectedSegment ?? model.hoveredSegment {
                    model.revealInFinder(segment)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selectedSegment == nil && model.hoveredSegment == nil)

            Button("Copy Path") {
                if let segment = model.selectedSegment ?? model.hoveredSegment {
                    model.copyPath(segment)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.selectedSegment == nil && model.hoveredSegment == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
