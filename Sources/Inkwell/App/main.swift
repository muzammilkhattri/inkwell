import Foundation

Perf.mark("main()")

// Inkwell was called Amailana; bring its data across before anything opens the database.
LegacyMigration.moveDataFolder()

// `Inkwell --mcp` runs the stdio MCP server for AI apps instead of the UI.
if CommandLine.arguments.contains("--mcp") {
    MCPServer.run()
}
if CommandLine.arguments.contains("--bench") {
    MainActor.assumeIsolated { Bench.run() }
}
if CommandLine.arguments.contains("--synctest") {
    MainActor.assumeIsolated { Bench.syncTest() }
}
if CommandLine.arguments.contains("--webtest") {
    MainActor.assumeIsolated { WebTest.run() }
}
if CommandLine.arguments.contains("--recvtest") {
    MainActor.assumeIsolated { RecvBench.run() }
}
// `INKWELL_HOME=/tmp/copy Inkwell --storagetest <months> [entire]`: report, estimate, clean up, report.
if CommandLine.arguments.contains("--storagetest") {
    let args = CommandLine.arguments
    let months = args.firstIndex(of: "--storagetest").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 6
    let ids = SettingsStore.load().accounts.map(\.id)
    let db = Database.shared
    func show(_ r: StorageManager.Report) {
        let b = StorageSettings.bytes
        print("total \(b(r.total)) | bodies \(b(r.bodies)) index \(b(r.index)) list \(b(r.list)) other \(b(r.other)) | \(r.emails) emails, \(r.downloaded) downloaded")
        for a in r.accounts { print("  account \(a.id.uuidString.prefix(8)): \(a.emails) emails, oldest \(a.oldest.map { "\($0)" } ?? "-"), \(b(a.bytes))") }
    }
    show(StorageManager.report(db: db, accountIds: ids))
    let o = StorageManager.Options(olderThanMonths: months, accountIds: [], entireEmails: args.contains("entire"), keepImportant: true)
    let e = StorageManager.estimate(db: db, o, allAccounts: ids)
    print("estimate: \(e.emails) emails, \(StorageSettings.bytes(e.bytes))")
    let t0 = Date()
    let r = StorageManager.cleanUp(db: db, o, allAccounts: ids)
    print("cleaned: \(r.emails) emails, freed \(StorageSettings.bytes(r.freed)) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    show(StorageManager.report(db: db, accountIds: ids))
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

InkwellApp.main()
