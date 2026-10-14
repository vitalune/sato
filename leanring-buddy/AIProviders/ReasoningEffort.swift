//
//  ReasoningEffort.swift
//  leanring-buddy
//
//  Per-model reasoning effort. Providers expose effort differently
//  (Anthropic `output_config.effort`, OpenAI `reasoning.effort`, Ollama
//  `think`) and every model accepts its own subset of levels, so each model
//  declares the levels it supports and the effort slider offers only those.
//

import Foundation

/// One selectable stop on the effort slider.
struct ReasoningEffortLevel: Hashable {
    /// The exact value sent to the provider API for this level.
    let apiValue: String
    let displayName: String

    static let none = ReasoningEffortLevel(apiValue: "none", displayName: "None")
    static let low = ReasoningEffortLevel(apiValue: "low", displayName: "Low")
    static let medium = ReasoningEffortLevel(apiValue: "medium", displayName: "Medium")
    static let high = ReasoningEffortLevel(apiValue: "high", displayName: "High")
    static let extraHigh = ReasoningEffortLevel(apiValue: "xhigh", displayName: "X-High")
    static let max = ReasoningEffortLevel(apiValue: "max", displayName: "Max")

    /// Ollama models that can only switch thinking off or on.
    static let thinkingOff = ReasoningEffortLevel(apiValue: "off", displayName: "Off")
    static let thinkingOn = ReasoningEffortLevel(apiValue: "on", displayName: "On")
}

/// The effort levels one model accepts, ordered from least to most effort.
struct ReasoningEffortOptions: Hashable {
    let levels: [ReasoningEffortLevel]

    /// Used until the user picks a level for this model, and whenever a saved
    /// level is no longer supported by the model.
    let defaultLevel: ReasoningEffortLevel

    func level(forSavedAPIValue savedAPIValue: String?) -> ReasoningEffortLevel {
        levels.first { $0.apiValue == savedAPIValue } ?? defaultLevel
    }
}
