//
//  CollectionPicturePicker.swift
//  HelloNotes
//
//  Choose a picture already in the collection, to show it in a note — the
//  first of Insert Image's three sources (`EditorImageSource.collection`).
//  Nothing is copied: the note links to the picture where it is.
//
//  One view on both platforms, drawn in the app's chrome like every sheet. A
//  tap chooses, as a folder's tap opens in the cloud folder picker — there is
//  no selection for a second button to take.
//

import MarkdownCore
import Synchronization
import SwiftUI

struct CollectionPicturePicker: View {
    let collection: Collection?
    /// The note the picture is for, named in the caption under the list.
    let noteTitle: String
    var onChoose: (CollectionFile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Thumbnails already made, by file: a row scrolled away and back is not
    /// read again.
    @State private var thumbnails: [URL: PictureThumbnail.Made] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ChromeSheetBar("Insert Image") {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } trailing: {
                EmptyView()
            }
            // The prompt is all that is drawn, so it names the field.
            ChromeTextField("Find a picture", text: $query, prompt: "Find by name or folder")
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            ChromeDivider()
            content
            ChromeDivider()
            Text("A picture in the collection is linked where it is — “\(noteTitle)” shows it, and nothing is copied.")
                .font(Chrome.Style.caption)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .chromeSheetFrame(width: 520, height: 560)
    }

    /// The collection's pictures, newest first, narrowed by the search —
    /// what Edit and Preview draw (`PictureNames`), not every file the
    /// system calls an image: a camera's raw file, an icon or a Photoshop
    /// document is listed among the collection's files, and its link would
    /// show as a line of text.
    private var pictures: [CollectionFile] {
        guard let collection else { return [] }
        let words = query.split(separator: " ").map { $0.lowercased() }
        return collection.attachments
            .filter { PictureNames.isPicture($0.name) }
            .filter { file in
                guard !words.isEmpty else { return true }
                let haystack = (collection.place(of: file.url.path) ?? file.name).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .sorted { $0.lastModified > $1.lastModified }
    }

    @ViewBuilder
    private var content: some View {
        if let collection, !collection.showsNonNoteFiles {
            // The walk collects no file that is not a note while this is off,
            // so an empty list here would say the collection has no pictures.
            VStack(spacing: 12) {
                ChromeEmptyState("Pictures Aren’t Listed", systemImage: "photo.on.rectangle",
                                 description: Text("This collection lists its notes only. Show its other files to choose from its pictures."))
                Button("Show Non-Note Files") { collection.showsNonNoteFiles = true }
                    .buttonStyle(ChromePushStyle(prominent: true))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if collection == nil {
            ChromeEmptyState("No Collection", systemImage: "folder",
                             description: Text("This note is in no open collection."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let pictures = pictures
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(pictures) { file in
                        Button { onChoose(file); dismiss() } label: { row(file) }
                            .buttonStyle(ChromePlainStyle())
                    }
                }
                .padding(.vertical, 4)
            }
            .viewport()
            .background(Chrome.Colour.content)
            .overlay {
                if pictures.isEmpty {
                    ChromeEmptyState(query.isEmpty ? "No Pictures" : "No Matches", systemImage: "photo",
                                     description: Text(query.isEmpty
                                                       ? "There are no pictures in this collection yet."
                                                       : "No picture’s name or folder has “\(query)” in it."))
                }
            }
        }
    }

    private func row(_ file: CollectionFile) -> some View {
        HStack(spacing: 10) {
            PictureThumbnail(url: file.url, made: $thumbnails)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .foregroundStyle(Chrome.Colour.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder(of: file))
                    .font(Chrome.Style.caption)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(file.name)
        .accessibilityAddTraits(.isButton)
    }

    /// The picture's folder inside the collection, by text — the top of the
    /// collection when it is there.
    private func folder(of file: CollectionFile) -> String {
        guard let collection, let place = collection.place(of: file.url.path) else { return "" }
        let folder = (place as NSString).deletingLastPathComponent
        return folder.isEmpty ? collection.name : folder
    }
}

/// A picture's thumbnail in the list: read only when the file is on this
/// device — a list of an iCloud vault's pictures downloads none of them by
/// being scrolled — and made off the main actor, on the scans' lanes, where
/// the files a note shows are read (`FileIO.onScanLane`).
struct PictureThumbnail: View {
    let url: URL
    @Binding var made: [URL: Made]

    /// What a row shows: the thumbnail, or why there is none.
    enum Made: @unchecked Sendable {
        case picture(CGImage)
        case notHere
        case unreadable
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Chrome.Colour.chrome)
            switch made[url] {
            case .picture(let image):
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            case .notHere:
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
            case .unreadable, .none:
                Image(systemName: "photo")
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
            }
        }
        .frame(width: 40, height: 40)
        .task(id: url) {
            guard made[url] == nil else { return }
            let url = url
            // A row scrolled past, or a sheet closed, before its turn on the
            // lane reads nothing: the lanes are where a note's own pictures
            // are read, and a fling through a thousand photos queued a
            // thousand whole-file reads in front of them, still running after
            // the sheet had gone.
            let wanted = StillWanted()
            let result = await withTaskCancellationHandler {
                await FileIO.onScanLane(for: url) { () -> Made? in
                    guard wanted.still else { return nil }
                    guard FileIO.isMaterialized(at: url) else { return .notHere }
                    guard let data = try? FileIO.readData(at: url),
                          let image = PictureFile.thumbnail(data, maxPixels: 80) else { return .unreadable }
                    return .picture(image)
                }
            } onCancel: {
                wanted.giveUp()
            }
            if let result { made[url] = result }
        }
    }
}

/// Whether a row still wants its thumbnail: given up as its task is
/// cancelled, read on the lane, which has no task to ask.
private nonisolated final class StillWanted: Sendable {
    private let wanted = Atomic(true)

    func giveUp() { wanted.store(false, ordering: .relaxed) }
    var still: Bool { wanted.load(ordering: .relaxed) }
}
