import CryptoKit
import FeedFlowDomain
import Foundation

public struct BundledPrompt: Hashable, Sendable {
    public var template: PromptTemplate
    public var revision: PromptRevision

    public init(task: AITask, name: String, body: String, variables: [String]) {
        let templateID = PromptTemplateID(Self.stableUUID("template:\(task.rawValue)"))
        let revisionID = PromptRevisionID(Self.stableUUID("revision:\(task.rawValue):v1"))
        template = PromptTemplate(id: templateID, task: task, name: name, bundledDefaultRevisionID: revisionID)
        revision = PromptRevision(id: revisionID, templateID: templateID, origin: .bundled, body: body, variables: variables)
    }

    private static func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum BundledPromptCatalog {
    public static let all: [BundledPrompt] = [
        BundledPrompt(task: .eventTitle, name: "Event title", body: "Create a precise factual title from the cited evidence. Do not add unsupported claims.\nEvidence:\n{{evidence}}", variables: ["evidence"]),
        BundledPrompt(task: .eventSynthesis, name: "Event synthesis", body: "Synthesize only the supported developments. Preserve disagreement and cite evidence identifiers.\n{{evidence}}", variables: ["evidence"]),
        BundledPrompt(task: .ambiguousClustering, name: "Ambiguous clustering", body: "Decide whether the evidence spans describe the same development. Return a confidence and rationale.\n{{candidates}}", variables: ["candidates"]),
        BundledPrompt(task: .keyPoints, name: "Key points", body: "Return concise key points backed by exact evidence spans.\n{{article}}", variables: ["article"]),
        BundledPrompt(task: .translation, name: "Translation", body: "Translate faithfully into {{language}} and preserve named entities and uncertainty.\n{{selection}}", variables: ["language", "selection"]),
        BundledPrompt(task: .explainSelection, name: "Explain", body: "Explain the selected passage in its article context. Clearly mark inference.\nSelection: {{selection}}\nContext: {{context}}", variables: ["selection", "context"]),
        BundledPrompt(task: .summarizeSelection, name: "Summarize selection", body: "Summarize only the selected passage in its article context. Preserve qualifications and do not introduce unsupported claims.\nSelection: {{selection}}\nContext: {{context}}", variables: ["selection", "context"]),
        BundledPrompt(task: .askSelection, name: "Ask selection", body: "Answer the question using the selected passage and its supplied context. Cite the exact selection and clearly say when it does not answer.\nQuestion: {{question}}\nSelection: {{selection}}\nContext: {{context}}", variables: ["question", "selection", "context"]),
        BundledPrompt(task: .askArticle, name: "Ask article", body: "Answer using only this article and cite exact spans. Say when the article does not answer.\nQuestion: {{question}}\nArticle: {{article}}", variables: ["question", "article"]),
        BundledPrompt(task: .chinaGlobalComparison, name: "China ↔ Global", body: "Compare framing only across the supplied evidence-qualified coverage groups. Do not infer nationality from language.\n{{evidence}}", variables: ["evidence"]),
        BundledPrompt(task: .digestSynthesis, name: "Digest synthesis", body: "Write a concise briefing from ranked Events. Preserve provenance and material changes.\n{{events}}", variables: ["events"]),
    ]
}
