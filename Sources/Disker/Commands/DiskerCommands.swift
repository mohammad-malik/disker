import SwiftUI

/// Menu bar commands.
///
/// A Mac app without a menu bar is broken, and every action reachable by pointer needs a
/// keyboard equivalent — the menu bar is where users look first for a command they cannot find.
struct DiskerCommands: Commands {
    @Bindable var model: AppModel
    @Bindable var appearance: AppearanceController

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

            Divider()

            // The standard Mac gesture for removing what is selected. Acts only on an
            // explicit selection, never on whatever the pointer happens to be over.
            Button("Move Selected to Trash") {
                if let segment = model.selectedSegment {
                    model.requestDeletion(of: segment)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(
                model.selectedSegment == nil
                    || model.selectedSegment?.node.kind == .aggregate)
        }

        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Divider()

            // Disabled where there is nothing to inspect. Without the check this offered
            // "Hide Details" in Recommendations and Mole and toggled a preference whose
            // effect those sections immediately suppress — the menu claimed to have done
            // something the window never reflected.
            Button(model.showsInspector ? "Hide Details" : "Show Details") {
                model.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(!model.sectionSupportsInspector)

            // Routed through the shell's own helper rather than the responder chain. The
            // first responder lives inside the sidebar's list, so once the sidebar collapsed
            // there was nothing left to perform this and it could never be reopened.
            Button("Toggle Sidebar") {
                NSSplitViewController.toggleSidebarFromToolbar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
