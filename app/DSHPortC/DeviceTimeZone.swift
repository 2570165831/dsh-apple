//
//  DeviceTimeZone.swift
//  DSHPortC
//
//  Hands the device's time zone to the embedded Node.
//
//  WHY THIS EXISTS
//  ---------------
//  nodejs-mobile's iOS build has `v8_enable_i18n_support: 0`, so `Intl` is
//  absent and `sim/intl-shim.cjs` supplies a minimal `DateTimeFormat`. That
//  shim can compute UTC and explicit offsets exactly, but a named IANA zone
//  needs a transition table it does not have, so it used to answer "UTC" for
//  every named zone. Anything the Node side then formatted was 11 hours off for
//  a user in Australia/Sydney.
//
//  `Date` itself is fine — it reads the platform's `localtime_r`, measured
//  inside the simulator as `GMT+1100 (AEDT)`. So the missing piece is only the
//  zone rules, and the platform has them: `TimeZone.nextDaylightSavingTimeTransition(after:)`.
//
//  WHAT IS SENT
//  ------------
//  The zone identifier, its offset now, and every transition from a year ago to
//  two years ahead, each as "the offset in effect until this instant". A shim
//  that answers "offset at instant t" by walking these is exact for that window
//  and does not need a tz database.
//
//  The table is rebuilt on every launch, so a phone that travels (or an OS that
//  updates the zone rules) gets a correct table on the next start. That is
//  enough for a display formatter and is stated as such in the report.
//

import Foundation

enum DeviceTimeZone {
    /// A transition: from this instant on, `offsetSeconds` east of UTC applies.
    struct Transition: Codable {
        let at: Int          // epoch seconds, UTC
        let offsetSeconds: Int
        let name: String     // "AEST" / "AEDT" / "" — display only, never parsed
    }

    struct Snapshot: Codable {
        let identifier: String
        let offsetSeconds: Int
        let transitions: [Transition]
        let capturedAt: String
        /// How far ahead the table is authoritative. The shim uses the last
        /// entry's offset beyond this, which is what a display should do rather
        /// than guess a rule it was not given.
        let horizonSeconds: Int
    }

    /// Build the table for `zone` (default: the device's current zone).
    ///
    /// Iterates `nextDaylightSavingTimeTransition(after:)`, which returns nil for
    /// a zone without DST — in that case the table is a single constant offset,
    /// which is exact rather than a guess.
    static func snapshot(zone: TimeZone = .current,
                         pastYears: Double = 1,
                         futureYears: Double = 2) -> Snapshot {
        let now = Date()
        let start = now.addingTimeInterval(-pastYears * 365.25 * 24 * 3600)
        let end = now.addingTimeInterval(futureYears * 365.25 * 24 * 3600)

        var transitions: [Transition] = []
        // The offset in effect at `start` is the first table entry's offset.
        let opening = Transition(
            at: Int(start.timeIntervalSince1970),
            offsetSeconds: zone.secondsFromGMT(for: start),
            name: abbreviation(zone, at: start)
        )
        transitions.append(opening)

        var cursor = start
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            guard let next = zone.nextDaylightSavingTimeTransition(after: cursor), next <= end else { break }
            let after = next.addingTimeInterval(1)
            transitions.append(Transition(
                at: Int(next.timeIntervalSince1970),
                offsetSeconds: zone.secondsFromGMT(for: after),
                name: abbreviation(zone, at: after)
            ))
            // A second of slack so the same instant cannot be returned twice.
            cursor = after
        }

        return Snapshot(
            identifier: zone.identifier,
            offsetSeconds: zone.secondsFromGMT(for: now),
            transitions: transitions,
            capturedAt: ISO8601DateFormatter().string(from: now),
            horizonSeconds: Int(end.timeIntervalSince1970 - now.timeIntervalSince1970)
        )
    }

    private static func abbreviation(_ zone: TimeZone, at date: Date) -> String {
        zone.abbreviation(for: date) ?? ""
    }

    /// The snapshot as one JSON string, for the Node process's environment.
    ///
    /// The environment rather than a file: it is read exactly once, by a process
    /// this app starts, and a file would be a second thing to clean up. Nothing
    /// here is a secret — it is a time zone and a list of dates.
    static func environmentValue() -> String {
        let snapshot = snapshot()
        guard let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            // `{"identifier":"UTC","offsetSeconds":0,"transitions":[]}` is a
            // worse answer than a correct one but never a crash: the report
            // records this as a fallback rather than hiding it.
            return #"{"identifier":"UTC","offsetSeconds":0,"transitions":[],"capturedAt":"","horizonSeconds":0}"#
        }
        return text
    }
}
