//
//  ReviewExportPicker.swift
//  AppUI · Review
//
//  "Save to folder" (docs/02-spec.md § S5): the system document picker, in its
//  exporting form, over files the Sent screen has already written to a
//  temporary directory.
//
//  Exporting copies, so the temporary directory can be left to the system to
//  reap. The picker is used rather than `fileExporter` because the payload is
//  several files — `review.md` and the ink PNGs — not a single document type.
//

import SwiftUI
import UIKit

/// Lets the user place a copy of the review wherever they like.
struct ReviewExportPicker: UIViewControllerRepresentable {

    /// Files that already exist on disk. An empty list presents an empty
    /// picker rather than failing, which is the harmless outcome.
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
