//
//  ItemNotesSectionView.swift
//  Vision_clother
//
//  Item-Level Feedback (2026-07-27): the "Your notes" section of
//  `ItemDetailView` — the read/edit/delete surface for `Models/ItemNote.swift`.
//
//  This screen is the reason the note model is mutable at all. Notes arrive
//  from three sources (a tapped chip, an LLM reading the user's free-text
//  comment, or the user typing one here), and the inferred ones can land on
//  the wrong garment when an outfit contains two similar pieces. Every note
//  therefore shows where it came from and is one tap from being corrected or
//  removed — that is the safety valve for the whole closed loop, not an
//  optional convenience.
//

import SwiftUI
import SwiftData

struct ItemNotesSectionView: View {
    let itemID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var notes: [ItemNote] = []
    @State private var editingNote: EditingNote?
    @State private var isAddPresented = false

    /// A plain value snapshot of the note being edited, rather than the
    /// `ItemNote` itself: `@Model` objects can be invalidated underneath a
    /// presented sheet (the same hazard `Features/CLAUDE.md` documents around
    /// `List`-hosted presentation), and this view's own delete path deletes
    /// exactly the object the sheet would still be holding.
    private struct EditingNote: Identifiable {
        let id: UUID
        let text: String
        let severity: ItemNoteSeverity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VCSpacing.md) {
            header

            if notes.isEmpty {
                Text("No notes yet. Add one here, or tap a garment while rating an outfit to flag things like fit or comfort.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: VCSpacing.sm) {
                    ForEach(notes, id: \.id) { note in
                        noteRow(note)
                    }
                }
            }
        }
        .premiumCard(radius: VCRadius.control, material: .regularMaterial, padding: VCSpacing.lg)
        .onAppear(perform: reload)
        .sheet(item: $editingNote) { note in
            ItemNoteEditorView(
                initialText: note.text,
                initialSeverity: note.severity,
                onSave: { text, severity in
                    let repository = SyncingWardrobeRepository(modelContext: modelContext)
                    try? repository.updateItemNote(id: note.id, text: text, severity: severity)
                    reload()
                },
                onDelete: {
                    let repository = SyncingWardrobeRepository(modelContext: modelContext)
                    try? repository.deleteItemNote(id: note.id)
                    reload()
                }
            )
        }
        .sheet(isPresented: $isAddPresented) {
            ItemNoteEditorView(
                initialText: "",
                initialSeverity: .conditional,
                onSave: { text, severity in
                    let repository = SyncingWardrobeRepository(modelContext: modelContext)
                    try? repository.addItemNote(
                        itemID: itemID, text: text, severity: severity,
                        source: .user, context: .none
                    )
                    reload()
                },
                onDelete: nil
            )
        }
    }

    private var header: some View {
        HStack {
            Text("Your notes")
                .font(.headline)
            Spacer()
            Button {
                isAddPresented = true
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.subheadline)
            }
            .accessibilityLabel("Add a note about this item")
        }
    }

    private func noteRow(_ note: ItemNote) -> some View {
        Button {
            editingNote = EditingNote(id: note.id, text: note.text, severity: note.severity)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: VCSpacing.md) {
                Image(systemName: note.severity == .blocking ? "nosign" : "exclamationmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(note.severity == .blocking ? Color.red : VCAccentColor.brand)
                VStack(alignment: .leading, spacing: VCSpacing.xs) {
                    Text(note.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle(for: note))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Names the note's origin and, for a blocking note, what it's actually
    /// doing — "excluded from recommendations" is a consequence the user
    /// should be able to see and undo, not silent behavior.
    private func subtitle(for note: ItemNote) -> String {
        let origin = note.source.label
        guard note.severity == .blocking else { return origin }
        return "\(origin) · Excluded from recommendations"
    }

    private func reload() {
        let repository = SyncingWardrobeRepository(modelContext: modelContext)
        withAnimation(vcMotion(VCMotion.standard, reduceMotion: reduceMotion)) {
            notes = (try? repository.fetchItemNotes(for: itemID)) ?? []
        }
    }
}

/// Add/edit sheet. Deliberately tiny — free text plus the one decision that
/// actually changes app behavior (`conditional` vs `blocking`), with the
/// consequence of each spelled out rather than left to the label alone.
struct ItemNoteEditorView: View {
    let initialText: String
    let initialSeverity: ItemNoteSeverity
    let onSave: (String, ItemNoteSeverity) -> Void
    /// `nil` when adding — there's nothing to delete yet.
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var severity: ItemNoteSeverity = .conditional
    @State private var isDeleteAlertPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. runs loose", text: $text, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Note")
                } footer: {
                    Text("Keep it short — this is sent to the stylist with the item, so a few words work better than a sentence.")
                }

                Section {
                    Picker("How much should this matter?", selection: $severity) {
                        ForEach(ItemNoteSeverity.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Effect")
                } footer: {
                    Text(severity == .blocking
                         ? "This item won't be suggested in any outfit until you change or remove this note."
                         : "The stylist still uses this item, but avoids it when the note would matter — like a fit issue for a formal occasion.")
                }

                if let onDelete {
                    Section {
                        Button("Delete note", role: .destructive) {
                            isDeleteAlertPresented = true
                        }
                        .frame(maxWidth: .infinity)
                        .alert("Delete this note?", isPresented: $isDeleteAlertPresented) {
                            Button("Cancel", role: .cancel) {}
                            Button("Delete", role: .destructive) {
                                onDelete()
                                dismiss()
                            }
                        } message: {
                            Text("This note is removed for good — it isn't kept as history.")
                        }
                    }
                }
            }
            .navigationTitle(onDelete == nil ? "Add Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text, severity)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = initialText
                severity = initialSeverity
            }
        }
    }
}
