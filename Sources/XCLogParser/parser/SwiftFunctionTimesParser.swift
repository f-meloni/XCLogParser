// Copyright (c) 2019 Spotify AB.
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation

/// Parses Swift Function times generated by the SwiftCompiler
/// if you pass the flags `-Xfrontend -debug-time-function-bodies`
public class SwiftFunctionTimesParser {

    typealias FilePath = String

    private static let compilerFlag = "-debug-time-function-bodies"

    private static let invalidLoc = "<invalid loc>"

    lazy var functionRegexp: NSRegularExpression? = {
        let pattern = "\\t*([0-9]+\\.[0-9]+)ms\\t+(<invalid\\tloc>|[^\\t]+)\\t+(.+)\\r"
        return NSRegularExpression.fromPattern(pattern)
    }()

    /// Dictionary to store the raw function times indexed by its MD5 hash
    var rawTimes = [String: String]()

    /// Dictionary to store the function times found per filepath
    var functionsPerFile: [FilePath: [FunctionTime]]?

    public func parseFromLogSection(_ logSection: IDEActivityLogSection) {
        // if the swift file was compiled with the time function flag
        if logSection.commandDetailDesc.contains(SwiftFunctionTimesParser.compilerFlag) {
            let rawFunctionTimes = logSection.text
            // the log puts almost the same string in each swift file compilation step
            // we just check we don't have it already
            guard rawFunctionTimes.isEmpty == false,
                let md5 = rawFunctionTimes.md5(),
                rawTimes[md5] == nil
            else {
                    return
            }
            rawTimes[md5] = rawFunctionTimes
        }
    }

    public func parseRawTimes() {
        functionsPerFile = rawTimes.values.compactMap { rawTime -> [FunctionTime]? in
            parseFunctionTimes(from: rawTime)
        }.joined().reduce([FilePath: [FunctionTime]]()) { (functionsPerFile, functionTime)
        -> [FilePath: [FunctionTime]] in
            var functionsPerFile = functionsPerFile
            if var functions = functionsPerFile[functionTime.file] {
                functions.append(functionTime)
                functionsPerFile[functionTime.file] = functions
            } else {
                functionsPerFile[functionTime.file] = [functionTime]
            }
            return functionsPerFile
        }
    }

    public func findFunctionTimesForFilePath(_ filePath: String) -> [FunctionTime]? {
        return functionsPerFile?[filePath]
    }

    public func hasFunctionTimes() -> Bool {
        guard let functionsPerFile = functionsPerFile else {
            return false
        }
        return functionsPerFile.isEmpty == false
    }

    public func parseFunctionTimes(from string: String) -> [FunctionTime]? {
        guard let regexp = functionRegexp else {
            return nil
        }
        let range = NSRange(location: 0, length: string.count)
        let matches = regexp.matches(in: string, options: .reportProgress, range: range)
        let functionTimes = matches.compactMap { result -> FunctionTime? in
            let durationString = string.substring(result.range(at: 1))
            let file = string.substring(result.range(at: 2))
            // some entries are invalid, we discarded them
            if file == SwiftFunctionTimesParser.invalidLoc {
                return nil
            }

            let name = string.substring(result.range(at: 3))
            guard let (fileName, location) = parseFunctionLocation(file) else {
                return nil
            }
            // transform it to a file URL to match the one in IDELogSection.documentURL
            let fileURL = URL(fileURLWithPath: fileName).absoluteString
            guard let (line, column) = parseLocation(location) else {
                return nil
            }

            let duration = parseFunctionCompileDuration(durationString)
            return FunctionTime(file: fileURL,
                                durationMS: duration,
                                startingLine: line,
                                startingColumn: column,
                                signature: name)

        }
        return functionTimes
    }

    private func parseFunctionLocation(_ function: String) -> (String, String)? {
        guard let colonIndex = function.index(of: ":") else {
            return nil
        }
        let functionName = function[..<colonIndex]
        let locationIndex = function.index(after: colonIndex)
        let location = function[locationIndex...]

        return (String(functionName), String(location))
    }

    private func parseLocation(_ location: String) -> (Int, Int)? {
        guard let colonIndex = location.index(of: ":") else {
            return nil
        }
        let line = location[..<colonIndex]
        let columnIndex = location.index(after: colonIndex)
        let column = location[columnIndex...]
        guard let lineNumber = Int(String(line)),
            let columnNumber = Int(String(column)) else {
                return nil
        }
        return (lineNumber, columnNumber)
    }

    private func parseFunctionCompileDuration(_ durationString: String) -> Double {
        if let duration = Double(durationString) {
            return duration
        }
        return 0.0
    }
}