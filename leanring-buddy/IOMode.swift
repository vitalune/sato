//
//  IOMode.swift
//  leanring-buddy
//
//  Defines the available input/output modes for the AI pipeline.
//  Defaults to textToText since the Cloudflare Worker proxy is not
//  configured yet and voice requires it.
//

import Foundation

enum IOMode: String, CaseIterable {
    case voiceToVoice
    case voiceToText
    case textToText
    case textToVoice

    var displayName: String {
        switch self {
        case .voiceToVoice: return "Voice → Voice"
        case .voiceToText:  return "Voice → Text"
        case .textToText:   return "Text → Text"
        case .textToVoice:  return "Text → Voice"
        }
    }

    var requiresWorker: Bool {
        switch self {
        case .voiceToVoice, .voiceToText, .textToVoice: return true
        case .textToText: return false
        }
    }
}
