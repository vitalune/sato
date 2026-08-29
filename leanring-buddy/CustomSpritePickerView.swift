//
//  CustomSpritePickerView.swift
//  leanring-buddy
//
//  Searchable Petdex gallery presented from Sato's menu bar panel.
//

import AppKit
import Foundation
import SwiftUI

struct CustomSpritePickerView: View {
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var catalog: PetdexSpriteCatalog
    @ObservedObject private var spriteAnimationManager: SpriteAnimationManager

    let onClose: () -> Void
    let onSelectionComplete: () -> Void

    @State private var searchText = ""
    @State private var selectedKind: String?
    @State private var selectedVibe: String?
    @State private var selectedSort: PetdexCatalogSort = .mostInstalled
    @State private var areFiltersVisible = false
    @State private var searchDebounceTask: Task<Void, Never>?

    private let galleryColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    init(
        companionManager: CompanionManager,
        onClose: @escaping () -> Void,
        onSelectionComplete: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        catalog = companionManager.petdexSpriteCatalog
        spriteAnimationManager = companionManager.spriteAnimationManager
        self.onClose = onClose
        self.onSelectionComplete = onSelectionComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .background(DS.Colors.borderSubtle)

            searchAndFilters
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            galleryContent

            Divider()
                .background(DS.Colors.borderSubtle)

            attributionFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.background)
                .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 12)
        )
        .onAppear {
            catalog.clearInstallationError()
            catalog.loadInitialCatalogIfNeeded()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
        }
        .onChange(of: searchText) { _, _ in
            refreshCatalog(afterDebounce: true)
        }
        .onChange(of: selectedKind) { _, _ in
            refreshCatalog(afterDebounce: false)
        }
        .onChange(of: selectedVibe) { _, _ in
            refreshCatalog(afterDebounce: false)
        }
        .onChange(of: selectedSort) { _, _ in
            refreshCatalog(afterDebounce: false)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom sprites")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Choose a community pet for Sato")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(DS.Colors.surface2)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close custom sprites")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)

                    TextField("Search 4,000+ pets", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .overlay(IBeamCursorView())

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                Button {
                    withAnimation(.easeOut(duration: DS.Animation.fast)) {
                        areFiltersVisible.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11, weight: .medium))
                        Text("Filters")
                            .font(.system(size: 11, weight: .medium))
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(DS.Colors.accent))
                        }
                    }
                    .foregroundColor(
                        areFiltersVisible || activeFilterCount > 0
                            ? DS.Colors.textPrimary
                            : DS.Colors.textSecondary
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(
                                areFiltersVisible || activeFilterCount > 0
                                    ? DS.Colors.surface3
                                    : DS.Colors.surface2
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(
                                areFiltersVisible || activeFilterCount > 0
                                    ? DS.Colors.borderStrong
                                    : DS.Colors.borderSubtle,
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if areFiltersVisible {
                filterControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 10) {
            filterMenu(
                label: "Type",
                selection: $selectedKind,
                options: catalog.availableKinds.isEmpty
                    ? ["creature", "character", "object"]
                    : catalog.availableKinds
            )
            filterMenu(
                label: "Mood",
                selection: $selectedVibe,
                options: catalog.availableVibes.isEmpty
                    ? [
                        "cozy", "calm", "playful", "focused", "mystical", "wholesome",
                        "cheerful", "mischievous", "heroic", "edgy", "chaotic", "melancholic",
                    ]
                    : catalog.availableVibes
            )

            Picker("Sort", selection: $selectedSort) {
                ForEach(PetdexCatalogSort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if activeFilterCount > 0 {
                Button("Clear") {
                    selectedKind = nil
                    selectedVibe = nil
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }

    private func filterMenu(
        label: String,
        selection: Binding<String?>,
        options: [String]
    ) -> some View {
        Picker(label, selection: selection) {
            Text("All \(label.lowercased())s").tag(String?.none)
            ForEach(options, id: \.self) { option in
                Text(option.capitalized).tag(String?.some(option))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var galleryContent: some View {
        if catalog.isLoading && catalog.pets.isEmpty {
            skeletonGallery
        } else if let errorMessage = catalog.catalogErrorMessage,
                  catalog.pets.isEmpty {
            catalogErrorState(message: errorMessage)
        } else if catalog.pets.isEmpty {
            emptySearchState
        } else {
            loadedGallery
        }
    }

    private var loadedGallery: some View {
        VStack(spacing: 0) {
            HStack {
                Text(resultCountText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                if let installationErrorMessage = catalog.installationErrorMessage {
                    Text(installationErrorMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(1)
                } else if let catalogErrorMessage = catalog.catalogErrorMessage {
                    Text(catalogErrorMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: galleryColumns, spacing: 12) {
                    ForEach(catalog.pets) { pet in
                        PetdexPetSelectionTile(
                            pet: pet,
                            isSelected: spriteAnimationManager.activeSpriteDirectory == "petdex:\(pet.slug)",
                            isInstalling: catalog.installingPetSlug == pet.slug,
                            isSelectionDisabled: catalog.installingPetSlug != nil,
                            onSelect: {
                                selectPet(pet)
                            }
                        )
                    }
                }
                .padding(.horizontal, 18)

                if catalog.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 18)
                } else if catalog.pets.count < catalog.totalPetCount {
                    Button("Load more") {
                        catalog.loadMorePets()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(DS.Colors.surface2)
                    )
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var skeletonGallery: some View {
        LazyVGrid(columns: galleryColumns, spacing: 12) {
            ForEach(0..<9, id: \.self) { _ in
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface2)
                        .frame(height: 96)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.Colors.surface2)
                        .frame(width: 80, height: 9)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.Colors.surface1)
                        .frame(width: 54, height: 7)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func catalogErrorState(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Couldn’t load pets")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Button("Try again") {
                catalog.refresh(query: currentCatalogQuery)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(DS.Colors.accent))
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySearchState: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No pets match those filters")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Try a shorter search or clear a filter.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attributionFooter: some View {
        HStack(spacing: 4) {
            Text("Pet art belongs to its creators. Review each pet on")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)

            Button("Petdex") {
                if let petdexURL = URL(string: "https://petdex.dev") {
                    NSWorkspace.shared.open(petdexURL)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(DS.Colors.accentText)
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            if let activeCustomSpriteMetadata = spriteAnimationManager.activeCustomSpriteMetadata {
                Button {
                    NSWorkspace.shared.open(activeCustomSpriteMetadata.sourceURL)
                } label: {
                    HStack(spacing: 3) {
                        Text(
                            "\(activeCustomSpriteMetadata.displayName) "
                                + "by \(activeCustomSpriteMetadata.creatorName)"
                        )
                        .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7, weight: .semibold))
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open this pet's creator credit and details")
            } else {
                Text("Selected pet works offline")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var activeFilterCount: Int {
        [selectedKind, selectedVibe].compactMap { $0 }.count
    }

    private var currentCatalogQuery: PetdexCatalogQuery {
        PetdexCatalogQuery(
            searchText: searchText,
            kind: selectedKind,
            vibe: selectedVibe,
            sort: selectedSort
        )
    }

    private var resultCountText: String {
        let totalPetCount = catalog.totalPetCount
        if totalPetCount == 1 {
            return "1 pet"
        }
        return "\(totalPetCount.formatted()) pets"
    }

    private func refreshCatalog(afterDebounce: Bool) {
        searchDebounceTask?.cancel()
        let query = currentCatalogQuery

        searchDebounceTask = Task {
            if afterDebounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            catalog.refresh(query: query)
        }
    }

    private func selectPet(_ pet: PetdexPet) {
        guard catalog.installingPetSlug == nil else { return }
        companionManager.startPetdexSpriteSelection(pet) { didSelectPet in
            if didSelectPet {
                onSelectionComplete()
            }
        }
    }
}

private struct PetdexPetSelectionTile: View {
    let pet: PetdexPet
    let isSelected: Bool
    let isInstalling: Bool
    let isSelectionDisabled: Bool
    let onSelect: () -> Void

    @StateObject private var previewImageLoader = PetdexPreviewImageLoader()
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(isSelected || isHovering ? DS.Colors.surface3 : DS.Colors.surface2)
                        .frame(height: 96)

                    previewContent
                        .frame(height: 88)
                        .frame(maxWidth: .infinity)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(DS.Colors.textOnAccent, DS.Colors.accent)
                            .padding(7)
                    }

                    if isInstalling {
                        ZStack {
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.background.opacity(0.72))
                            ProgressView()
                                .controlSize(.small)
                                .tint(DS.Colors.textPrimary)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .stroke(
                            isSelected
                                ? DS.Colors.accent
                                : (isHovering ? DS.Colors.borderStrong : DS.Colors.borderSubtle),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )

                Text(pet.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    Text("by \(pet.submittedBy.name)")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .bold))
                    Text(abbreviatedCount(pet.metrics.installCount))
                }
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSelectionDisabled)
        .opacity(isSelectionDisabled && !isInstalling ? 0.55 : 1)
        .onHover { isHovering = $0 && !isSelectionDisabled }
        .pointerCursor(isEnabled: !isSelectionDisabled)
        .onAppear {
            previewImageLoader.loadPreview(for: pet)
        }
        .onDisappear {
            previewImageLoader.cancel()
        }
        .accessibilityLabel("\(pet.displayName), by \(pet.submittedBy.name)")
        .accessibilityHint(isSelected ? "Selected custom sprite" : "Download and use this sprite")
    }

    @ViewBuilder
    private var previewContent: some View {
        if let previewImage = previewImageLoader.previewImage {
            Image(nsImage: previewImage)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(.vertical, 4)
        } else if previewImageLoader.didFail {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
        } else {
            ProgressView()
                .controlSize(.mini)
                .tint(DS.Colors.textTertiary)
        }
    }

    private func abbreviatedCount(_ count: Int) -> String {
        if count >= 1_000 {
            let thousands = Double(count) / 1_000
            return String(format: thousands >= 10 ? "%.0fK" : "%.1fK", thousands)
        }
        return String(count)
    }
}
