#!/usr/bin/env xcrun swift
//
//  main.swift
//  AbandonedStrings
//
//  Created by Joshua Smith on 2/1/16.
//  Copyright © 2016 iJoshSmith. All rights reserved.
//

/*
 For overview and usage information refer to https://github.com/ijoshsmith/abandoned-strings
 */

import Foundation

// MARK: - File processing

let dispatchGroup = DispatchGroup.init()
let serialWriterQueue = DispatchQueue.init(label: "writer")

func findFilesIn(_ directories: [String], withExtensions extensions: [String]) -> [String] {
  let fileManager = FileManager.default
  var files = [String]()
  for directory in directories {
    guard let enumerator: FileManager.DirectoryEnumerator = fileManager.enumerator(atPath: directory) else {
      print("Failed to create enumerator for directory: \(directory)")
      return []
    }
    while let path = enumerator.nextObject() as? String {
      let fileExtension = (path as NSString).pathExtension.lowercased()
      if extensions.contains(fileExtension) {
        let fullPath = (directory as NSString).appendingPathComponent(path)
        files.append(fullPath)
      }
    }
  }
  return files
}

func contentsOfFile(_ filePath: String) -> String {
  do {
    return try String(contentsOfFile: filePath)
  }
  catch {
    print("cannot read file!!!")
    exit(1)
  }
}

func concatenateAllSourceCodeIn(_ directories: [String], withStoryboard: Bool) -> String {
  var extensions = ["h", "m", "swift"]
  if withStoryboard {
    extensions.append("storyboard")
  }
  let sourceFiles = findFilesIn(directories, withExtensions: extensions)
  return sourceFiles.reduce("") { (accumulator, sourceFile) -> String in
    return accumulator + contentsOfFile(sourceFile)
  }
}

// MARK: - Identifier extraction

let doubleQuote = "\""

func retriveL10nUsage(fromFileContent content: String) -> [String] {
  do {
    let regex = try NSRegularExpression(pattern: #"(L10n\.[a-zA-Z0-9.]+)|(\"\@.*\")"#)
    let results = regex.matches(
      in: content,
      range: NSRange(content.startIndex..., in: content)
    )
    return results.map {
      String(content[Range($0.range, in: content)!]).lowercased()
    }
  } catch let error {
    print("invalid regex: \(error.localizedDescription)")
    return []
  }
}

func extractStringIdentifiersFrom(_ stringsFile: String) -> [String] {
  return contentsOfFile(stringsFile)
    .components(separatedBy: "\n")
    .filter { $0.hasPrefix(doubleQuote) }
    .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
    .compactMap { extractStringIdentifierFromTrimmedLine($0) }
}

func extractStringIdentifierFromTrimmedLine(_ line: String) -> String? {
  let indexAfterFirstQuote = line.index(after: line.startIndex)
  guard let endIndex = line[indexAfterFirstQuote...].firstIndex(of:"\"") else {
    print("Cannot extract id for line \"\(line)\"")
    return nil
  }
  let identifier = line[indexAfterFirstQuote..<endIndex]
  return String(identifier)
}

// MARK: - Abandoned identifier detection

func findStringIdentifiersIn(_ stringsFile: String, usageSet: Set<String>) -> [String] {
  return extractStringIdentifiersFrom(stringsFile).filter { identifier in
    let l10nUsage = identifier.toL10nGenerated()
    let quotedIdentifierForStoryboard = "\"@\(identifier)\""

    return !(usageSet.contains(l10nUsage) || usageSet.contains(quotedIdentifierForStoryboard))
  }
}

typealias StringsFileToAbandonedIdentifiersMap = [String: [String]]

func findAbandonedIdentifiersIn(_ rootDirectories: [String], withStoryboard: Bool) -> StringsFileToAbandonedIdentifiersMap {
  var map = StringsFileToAbandonedIdentifiersMap()
  let sourceCode = concatenateAllSourceCodeIn(rootDirectories, withStoryboard: withStoryboard)
  let l10nUsageSet = Set(retriveL10nUsage(fromFileContent: sourceCode))
  let stringsFiles = findFilesIn(rootDirectories, withExtensions: ["strings"])
  for stringsFile in stringsFiles {
    dispatchGroup.enter()
    DispatchQueue.global().async {
      let abandonedIdentifiers = findStringIdentifiersIn(stringsFile, usageSet: l10nUsageSet)
      if abandonedIdentifiers.isEmpty == false {
        serialWriterQueue.async {
          map[stringsFile] = abandonedIdentifiers
          dispatchGroup.leave()
        }
      } else {
        NSLog("\(stringsFile) has no abandonedIdentifiers")
        dispatchGroup.leave()
      }
    }
  }
  dispatchGroup.wait()
  return map
}

extension String {
  func toL10nGenerated() -> String {
    let splitArray = self
      .split(separator: ".")

    let generated = splitArray
      .enumerated()
      .map {
        String($0.element).toCamelCase(cap: $0.offset != splitArray.endIndex - 1 && splitArray.count != 1 )
      }
      .joined(separator: ".")

    // TODO: there seems to be some fancy logic SwiftGen is doing for camel cases, dont want to deal with them now so `.lowercased()`
    return "L10n.\(generated)".lowercased()
  }

  func toCamelCase(cap: Bool) -> Self {
    return self
      .lowercased()
      .split(separator: "_")
      .enumerated()
      .map { ($0.offset > 0 || cap) ? $0.element.capitalized : $0.element.lowercased() }
      .joined()
  }
}

// MARK: - Engine

func getRootDirectories() -> [String]? {
  var c = [String]()
  for arg in CommandLine.arguments {
    c.append(arg)
  }
  c.remove(at: 0)
  if isOptionalParameterForStoryboardAvailable() {
    c.removeLast()
  }
  if isOptionaParameterForWritingAvailable() {
    c.remove(at: c.index(of: "write")!)
  }
  return c
}

func isOptionalParameterForStoryboardAvailable() -> Bool {
  return CommandLine.arguments.last == "storyboard"
}

func isOptionaParameterForWritingAvailable() -> Bool {
  return CommandLine.arguments.contains("write")
}

func displayAbandonedIdentifiersInMap(_ map: StringsFileToAbandonedIdentifiersMap) {
  for file in map.keys.sorted() {
    print("\(file)")
    for identifier in map[file]!.sorted() {
      print("  \(identifier) \(identifier.toL10nGenerated())")
    }
    print("")
  }
}

if let rootDirectories = getRootDirectories() {
  print("Searching for abandoned resource strings…")
  let withStoryboard = isOptionalParameterForStoryboardAvailable()
  let map = findAbandonedIdentifiersIn(rootDirectories, withStoryboard: withStoryboard)
  if map.isEmpty {
    print("No abandoned resource strings were detected.")
  }
  else {
    print("Abandoned resource strings were detected:")
    displayAbandonedIdentifiersInMap(map)

    if isOptionaParameterForWritingAvailable() {
      // TODO: implement this
    }
  }
} else {
  print("Please provide the root directory for source code files as a command line argument.")
}
