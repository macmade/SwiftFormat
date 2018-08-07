//
//  Arguments.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 07/08/2018.
//  Copyright © 2018 Nick Lockwood.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

extension Options {
    init(_ args: [String: String], in directory: String) throws {
        try self.init(args)
        fileOptions = try fileOptionsFor(args, in: directory)
    }

    init(_ args: [String: String]) throws {
        fileOptions = nil
        formatOptions = try formatOptionsFor(args)
        rules = try rulesFor(args)
    }
}

// Parse a space-delimited string into an array of command-line arguments
// Replicates the behavior implemented by the console when parsing input
func parseArguments(_ argumentString: String) -> [String] {
    var arguments = [""] // Arguments always begin with script path
    var characters = String.UnicodeScalarView.SubSequence(argumentString.unicodeScalars)
    var string = ""
    var escaped = false
    var quoted = false
    while let char = characters.popFirst() {
        switch char {
        case "\\" where !escaped:
            escaped = true
        case "\"" where !escaped && !quoted:
            quoted = true
        case "\"" where !escaped && quoted:
            quoted = false
            fallthrough
        case " " where !escaped && !quoted:
            if !string.isEmpty {
                arguments.append(string)
            }
            string.removeAll()
        case "\"" where escaped:
            escaped = false
            string.append("\"")
        case _ where escaped && quoted:
            string.append("\\")
            fallthrough
        default:
            escaped = false
            string.append(Character(char))
        }
    }
    if !string.isEmpty {
        arguments.append(string)
    }
    return arguments
}

// Parse a flat array of command-line arguments into a dictionary of flags and values
func preprocessArguments(_ args: [String], _ names: [String]) throws -> [String: String] {
    var anonymousArgs = 0
    var namedArgs: [String: String] = [:]
    var name = ""
    for arg in args {
        if arg.hasPrefix("--") {
            // Long argument names
            let key = String(arg.unicodeScalars.dropFirst(2))
            if !names.contains(key) {
                throw FormatError.options("unknown option --\(key)")
            }
            name = key
            namedArgs[name] = ""
            continue
        } else if arg.hasPrefix("-") {
            // Short argument names
            let flag = String(arg.unicodeScalars.dropFirst())
            let matches = names.filter { $0.hasPrefix(flag) }
            if matches.count > 1 {
                throw FormatError.options("ambiguous flag -\(flag)")
            } else if matches.count == 0 {
                throw FormatError.options("unknown flag -\(flag)")
            } else {
                name = matches[0]
                namedArgs[name] = ""
            }
            continue
        }
        if name == "" {
            // Argument is anonymous
            name = String(anonymousArgs)
            anonymousArgs += 1
        }
        namedArgs[name] = arg
        name = ""
    }
    return namedArgs
}

// Parse a comma-delimited rules string into an array of rules
let allRules = Set(FormatRules.byName.keys)
func parseRules(_ rules: String) throws -> [String] {
    return try rules.components(separatedBy: ",").compactMap {
        let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return nil
        } else if !allRules.contains(name) {
            throw FormatError.options("unknown rule '\(name)'")
        }
        return name
    }
}

// Merge two dictionaries of arguments
func mergeArguments(_ args: [String: String], into config: [String: String]) throws -> [String: String] {
    var input = config
    var output = args
    // Merge excluded urls
    if let exclude = output["exclude"]?.components(separatedBy: ",") {
        var excluded = Set(input["exclude"]?.components(separatedBy: ",") ?? [])
        excluded.formUnion(exclude)
        output["exclude"] = Array(excluded).sorted().joined(separator: ",")
    }
    // Merge rules
    if let rules = try output["rules"].map(parseRules) {
        if rules.isEmpty {
            output["rules"] = nil
        } else {
            input["rules"] = nil
            input["enable"] = nil
            input["disable"] = nil
        }
    } else {
        if let _disable = try output["disable"].map(parseRules) {
            if let rules = try input["rules"].map(parseRules) {
                input["rules"] = Set(rules).subtracting(_disable).sorted().joined(separator: ",")
            }
            if let enable = try input["enable"].map(parseRules) {
                input["enable"] = Set(enable).subtracting(_disable).sorted().joined(separator: ",")
            }
            if let disable = try input["disable"].map(parseRules) {
                input["disable"] = Set(disable).union(_disable).sorted().joined(separator: ",")
                output["disable"] = nil
            }
        }
        if let _enable = try args["enable"].map(parseRules) {
            if let enable = try input["enable"].map(parseRules) {
                input["enable"] = Set(enable).union(_enable).sorted().joined(separator: ",")
                output["enable"] = nil
            }
            if let disable = try input["disable"].map(parseRules) {
                input["disable"] = Set(disable).subtracting(_enable).sorted().joined(separator: ",")
            }
        }
    }
    // Merge other arguments
    for (key, value) in input where output[key] == nil {
        output[key] = value
    }
    return output
}

// Parse a configuration file into a dictionary of arguments
func parseConfigFile(_ data: Data) throws -> [String: String] {
    guard let input = String(data: data, encoding: .utf8) else {
        throw FormatError.reading("unable to read data for configuration file")
    }
    let lines = input.components(separatedBy: .newlines)
    let arguments = try lines.flatMap { line -> [String] in
        // TODO: parseArguments isn't a perfect fit here - should we use a different approach?
        let parts = parseArguments(line.replacingOccurrences(of: "\\n", with: "\n")).dropFirst().map {
            $0.replacingOccurrences(of: "\n", with: "\\n")
        }
        guard let key = parts.first else {
            return []
        }
        if !key.hasPrefix("-") {
            throw FormatError.options("unknown option \(key)")
        }
        return [key, parts.dropFirst().joined(separator: " ")]
    }
    return try preprocessArguments(arguments, commandLineArguments)
}

// Serialize a set of options into either an arguments string or a file
func serialize(options: Options,
               excludingDefaults: Bool = false,
               separator: String = "\n") -> String {
    var result = ""
    if let options = options.formatOptions {
        result += argumentsFor(options, excludingDefaults: excludingDefaults).map {
            var value = $1
            if value.contains(" ") {
                value = "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return "--\($0) \(value)"
        }.sorted().joined(separator: separator)
    }
    if let rules = options.rules {
        let defaultRules = allRules.subtracting(FormatRules.disabledByDefault)

        let enabled = rules.subtracting(defaultRules)
        if !enabled.isEmpty {
            result += "\(separator)--enable \(enabled.sorted().joined(separator: ","))"
        }

        let disabled = defaultRules.subtracting(rules)
        if !disabled.isEmpty {
            result += "\(separator)--disable \(disabled.sorted().joined(separator: ","))"
        }
    }
    return result
}

// Get command line arguments for formatting options
// (excludes non-formatting options and deprecated/renamed options)
func argumentsFor(_ options: FormatOptions, excludingDefaults: Bool = false) -> [String: String] {
    var args = [String: String]()
    for descriptor in FormatOptions.Descriptor.formatting where !descriptor.isDeprecated {
        let value = descriptor.fromOptions(options)
        if !excludingDefaults || value != descriptor.fromOptions(.default) {
            args[descriptor.argumentName] = value
        }
    }
    return args
}

private func processOption(_ key: String,
                           in args: [String: String],
                           from: inout Set<String>,
                           handler: (String) throws -> Void) throws {
    precondition(commandLineArguments.contains(key))
    var arguments = from
    arguments.remove(key)
    from = arguments
    guard let value = args[key] else {
        return
    }
    guard !value.isEmpty else {
        throw FormatError.options("--\(key) option expects a value")
    }
    do {
        try handler(value)
    } catch {
        throw FormatError.options("unsupported --\(key) value '\(value)'")
    }
}

// Parse rule names from arguments
func rulesFor(_ args: [String: String]) throws -> Set<String> {
    var rules = allRules
    rules = try args["rules"].map {
        try Set(parseRules($0))
    } ?? rules.subtracting(FormatRules.disabledByDefault)
    try args["enable"].map {
        try rules.formUnion(parseRules($0))
    }
    try args["disable"].map {
        try rules.subtract(parseRules($0))
    }
    return rules
}

// Parse FileOptions from arguments
func fileOptionsFor(_ args: [String: String], in directory: String) throws -> FileOptions? {
    var options = FileOptions()
    var arguments = Set(fileArguments)

    var containsFileOption = false
    try processOption("symlinks", in: args, from: &arguments) {
        containsFileOption = true
        switch $0.lowercased() {
        case "follow":
            options.followSymlinks = true
        case "ignore":
            options.followSymlinks = false
        default:
            throw FormatError.options("")
        }
    }
    try processOption("exclude", in: args, from: &arguments) {
        containsFileOption = true
        for path in $0.components(separatedBy: ",") {
            options.excludedURLs.append(expandPath(path, in: directory))
        }
    }
    assert(arguments.isEmpty, "\(arguments.joined(separator: ","))")
    return containsFileOption ? options : nil
}

// Parse FormatOptions from arguments
// Returns nil if the arguments dictionary does not contain any formatting arguments
func formatOptionsFor(_ args: [String: String]) throws -> FormatOptions? {
    var options = FormatOptions.default
    var arguments = Set(formattingArguments)

    var containsFormatOption = false
    for option in FormatOptions.Descriptor.all {
        try processOption(option.argumentName, in: args, from: &arguments) {
            containsFormatOption = true
            try option.toOptions($0, &options)
        }
    }
    assert(arguments.isEmpty, "\(arguments.joined(separator: ","))")
    return containsFormatOption ? options : nil
}

// Get deprecation warnings from a set of arguments
func warningsForArguments(_ args: [String: String]) -> [String] {
    var warnings = [String]()
    for option in FormatOptions.Descriptor.all {
        if args[option.argumentName] != nil, let message = option.deprecationMessage {
            warnings.append(message)
        }
    }
    return warnings
}

let fileArguments = [
    "symlinks",
    "exclude",
]

let rulesArguments = [
    "disable",
    "enable",
    "rules",
]

let formattingArguments = FormatOptions.Descriptor.formatting.map { $0.argumentName }
let internalArguments = FormatOptions.Descriptor.internal.map { $0.argumentName }

let commandLineArguments = [
    // Input options
    "config",
    "inferoptions",
    "output",
    "cache",
    "verbose",
    "dryrun",
    "lint",
    // Misc
    "help",
    "version",
] + fileArguments + rulesArguments + formattingArguments + internalArguments

let deprecatedArguments = FormatOptions.Descriptor.all.compactMap {
    $0.isDeprecated ? $0.argumentName : nil
}