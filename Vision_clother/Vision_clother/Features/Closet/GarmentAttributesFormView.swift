//
//  GarmentAttributesFormView.swift
//  Vision_clother
//
//  The garment attributes `Form`, extracted from `AddItemView.editForm` so
//  it can back both manual entry (`AddItemView`) and edit-after-save
//  (`EditItemView`) without duplicating the field UI.
//

import SwiftUI

struct GarmentAttributesFormView: View {
    @Bindable var model: GarmentAttributesEditorModel
    let previewImageData: Data?
    let saveButtonLabel: String
    let onSave: () -> Void
    /// Quota visibility feature: non-`nil` when the currently selected
    /// `model.slot` category is at its item cap (`Data/UsageTracker.swift`'s
    /// `itemCap(for:)`) — disables Save and shows the reason inline. `nil`
    /// for `EditItemView`'s call site (re-slotting an already-owned item
    /// isn't a net-new item, so no cap check applies there), which is why
    /// this defaults to `nil` rather than being required.
    var capMessage: String? = nil

    var body: some View {
        Form {
            Section("Garment Preview") {
                HStack {
                    Spacer()
                    if let previewImageData, let uiImage = UIImage(data: previewImageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 120)
                            .clipShape(VCRadius.shape(VCRadius.swatch))
                    } else {
                        VCRadius.shape(VCRadius.swatch)
                            .fill(Color(hex: model.primaryHex) ?? .gray)
                            .frame(width: 80, height: 80)
                            .overlay {
                                Image(systemName: "tshirt.fill")
                                    .foregroundStyle(.white)
                                    .font(.title2)
                            }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Attributes") {
                Picker("Category", selection: $model.slot) {
                    ForEach(Slot.allCases) { slot in
                        Text(slot.rawValue.capitalized).tag(slot)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Formality Score")
                        Spacer()
                        Text(String(format: "%.1f", model.formalityScore))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.formalityScore, in: 1.0...5.0, step: 0.5)
                    HStack {
                        Text("Casual (1.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Business (3.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Formal (5.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ColorPicker("Garment Color", selection: Binding(
                    get: { Color(hex: model.primaryHex) ?? .white },
                    set: { newColor in
                        if let hex = newColor.toHex() {
                            model.primaryHex = hex
                        }
                    }
                ))

                Picker("Color Vibe", selection: $model.colorCategory) {
                    ForEach(ColorVibe.allCases, id: \.self) { vibe in
                        Text(vibe.rawValue.replacingOccurrences(of: "_", with: " ").capitalized).tag(vibe)
                    }
                }

                Picker("Undertone", selection: $model.undertone) {
                    Text("Unknown").tag(Undertone?.none)
                    ForEach(Undertone.allCases, id: \.self) { tone in
                        Text(tone.rawValue.capitalized).tag(Undertone?.some(tone))
                    }
                }

                Picker("Pattern", selection: $model.pattern) {
                    ForEach(GarmentPattern.allCases, id: \.self) { pat in
                        Text(pat.rawValue.capitalized).tag(pat)
                    }
                }

                Picker("Fabric Weight", selection: $model.fabricWeight) {
                    ForEach(FabricWeight.allCases, id: \.self) { weight in
                        Text(weight.rawValue.capitalized).tag(weight)
                    }
                }
            }

            Section("Fit & Material") {
                TextField("Garment Subtype (e.g. Oxford Shirt)", text: $model.garmentSubtype)
                TextField("Fit (e.g. Oversized, Slim, Regular)", text: $model.fit)
                TextField("Silhouette (e.g. Straight, Boxy, Fitted)", text: $model.silhouette)
                TextField("Material (e.g. Linen, Cotton, Denim)", text: $model.material)
                TextField("Texture (e.g. Ribbed, Knit, Smooth)", text: $model.texture)
            }

            Section("Description") {
                TextField("e.g. Charcoal crewneck tee in a soft cotton blend", text: $model.itemDescription, axis: .vertical)
                    .lineLimit(2...4)
                if !model.styleTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(model.styleTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, VCSpacing.sm)
                                    .padding(.vertical, VCSpacing.xs)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                    }
                }
            }

            Section("Seasonality") {
                ForEach(Season.allCases, id: \.self) { season in
                    Toggle(season.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(
                        get: { model.seasonality.contains(season) },
                        set: { isSelected in
                            if isSelected {
                                if !model.seasonality.contains(season) {
                                    model.seasonality.append(season)
                                }
                            } else {
                                model.seasonality.removeAll { $0 == season }
                            }
                        }
                    ))
                }
            }

            if let capMessage {
                Label(capMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                onSave()
            } label: {
                Text(saveButtonLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(capMessage != nil)
            .listRowBackground(Color.clear)
        }
    }
}
