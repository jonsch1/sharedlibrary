import BrieflyCore
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: briefly-migrate <markdown-workspace>\n".utf8))
    exit(2)
}

do {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let databaseURL = root
        .appending(path: ".briefly", directoryHint: .isDirectory)
        .appending(path: "library.sqlite3")
    let library = SQLiteLibraryStore(databaseURL: databaseURL)
    let count = try await library.ingestMarkdownLibrary(from: root)
    print("Imported \(count) documents into \(root.path)/.briefly/library.sqlite3")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
