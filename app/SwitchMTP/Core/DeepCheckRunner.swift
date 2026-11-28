// SwitchMTP Batch — a macOS MTP client for Nintendo Switch running DBI.
// Copyright (C) 2025 fratei
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 2 as published by
// the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.

import Foundation

/// Serial deep-verification pass shared by the GUI workspace and the CLI.
///
/// The runner itself does no queueing, no UI updates and no keyset lifecycle
/// management: the caller decides which thread to run on, writes results back
/// to its own state, and owns the ephemeral keyset copy
/// (`KeySetStore.makeEphemeralCopy` / `discard`).
struct DeepCheckRunner {

    /// One package waiting for the deep pass.
    struct Job: Identifiable, Sendable {
        let id: InstallPackage.ID
        let url: URL
        let format: PackageFormat
        let expectedNCAs: Int?
        let entrySizes: [String: Int64]
    }

    /// Builds jobs from packages, capturing the structural pass's NCA table so
    /// the verifier can seek straight to an NCA without re-walking the container.
    static func jobs(for packages: [InstallPackage]) -> [Job] {
        packages.map { package in
            let sizes = package.report?.entries.reduce(into: [String: Int64]()) {
                $0[$1.name] = $1.size
            } ?? [:]
            return Job(
                id: package.id,
                url: package.url,
                format: package.format,
                expectedNCAs: package.report?.ncaCount,
                entrySizes: sizes)
        }
    }

    /// A `title.keys` sitting next to `prod.keys`, when present. Optional: the
    /// engine recovers title keys from the package's own tickets otherwise.
    static func titleKeysURL(for keysetPath: String) -> URL? {
        let sibling = URL(fileURLWithPath: keysetPath)
            .deletingLastPathComponent()
            .appendingPathComponent("title.keys")
        return FileManager.default.isReadableFile(atPath: sibling.path) ? sibling : nil
    }

    /// Verifies `jobs` one after another. Blocks the calling thread for the
    /// duration; call from a background queue.
    ///
    /// - Parameter keysetURL: Ephemeral keyset copy. When nil every job falls
    ///   back to an `.unavailable` result, matching the no-keyset degraded pass.
    /// - Parameter shouldStop: Checked before each job. When it returns true,
    ///   the current job finishes first (it is never killed mid-run), then the
    ///   rest are left untouched and returned so a later resume can pick them
    ///   up.
    /// - Parameters:
    ///   - onProgress: Per-job 0...1 fraction plus a short stage label.
    ///   - onResult: Delivered after each job finishes, whatever the verdict.
    /// - Returns: Jobs left unrun because the pass was paused.
    @discardableResult
    static func run(jobs: [Job],
                    keysetURL: URL?,
                    titleKeysURL: URL?,
                    hactoolURL: URL,
                    shouldStop: () -> Bool,
                    onProgress: @escaping (Job, Double, String) -> Void,
                    onResult: @escaping (Job, DeepResult) -> Void) -> [Job] {
        var remaining: [Job] = []
        for job in jobs {
            if shouldStop() {
                remaining.append(job)
                continue
            }
            let result: DeepResult
            if let keysetURL {
                result = DeepVerifier.verify(
                    url: job.url,
                    format: job.format,
                    keysetURL: keysetURL,
                    titleKeysURL: titleKeysURL,
                    hactoolURL: hactoolURL,
                    expectedNCAs: job.expectedNCAs,
                    entrySizes: job.entrySizes,
                    progress: { fraction, phase in
                        onProgress(job, fraction, phase)
                    })
            } else {
                result = DeepResult(state: .unavailable, notes: [
                    .init(severity: .warning, title: "密钥文件不可读", detail: "本次只完成结构检查。")
                ], detail: "无法读取 prod.keys")
            }
            onResult(job, result)
        }
        return remaining
    }
}
