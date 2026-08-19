//
//  ReviewShareSheet.swift
//  AppUI · Review
//
//  The system share sheet, holding the review's prose and its marked-up pages
//  as images (docs/06-integrations.md § The universal fallback).
//
//  A `UIActivityViewController` rather than SwiftUI's `ShareLink` because the
//  payload is a mixed bag — one string and n images built in memory — and the
//  activity controller takes exactly that with no `Transferable` plumbing.
//

import SwiftUI
import UIKit

/// Presents the marked-up pages and the review text to the share sheet.
struct ReviewShareSheet: UIViewControllerRepresentable {

    /// Strings and `UIImage`s, in the order the receiving app should see them.
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
