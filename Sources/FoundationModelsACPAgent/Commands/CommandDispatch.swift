import Foundation
import FoundationModelsACP
import FoundationModelsExtras

/// One parsed leading slash command of a prompt request (plan.md
/// §14.3): the bare name, the raw argument text, and the content
/// blocks that came with the command.
struct ParsedCommand: Sendable {
    /// The bare command name, no leading slash.
    let name: String

    /// The raw text after `/name `, leading whitespace dropped.
    let arguments: String

    /// The content blocks after the command's text block. They carry
    /// into a prompt-style or `.rendered` turn; an `.action` command
    /// refuses them (plan.md §14.3).
    let attachments: [ContentBlock]
}

/// The dispatch mechanics of the prompt owner (plan.md §14.3): the
/// leading-slash parse, the `.prompt` template expansion, and the model
/// prompt assembly.
enum CommandDispatch {
    /// The one-character prefix that marks a command.
    static let commandPrefix = "/"

    /// The template-context key that carries the raw argument text into
    /// a `.prompt` expansion.
    static let argumentsTemplateKey = "arguments"

    /// Parses a leading `/name` from the prompt blocks.
    ///
    /// The command must be the first block, must be text, and must
    /// start with ``commandPrefix`` followed by at least one non-space
    /// character. A lone slash is not a command; a literal leading
    /// slash is the frontend's escaping problem (plan.md §14.3).
    ///
    /// - Parameter blocks: The request's content blocks.
    /// - Returns: The parsed command, or `nil` when the prompt is not a
    ///   command.
    static func parseCommand(blocks: [ContentBlock]) -> ParsedCommand? {
        guard let first = blocks.first, case .text(let content) = first,
            content.text.hasPrefix(commandPrefix)
        else {
            return nil
        }
        let afterSlash = content.text.dropFirst(commandPrefix.count)
        let name = afterSlash.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        let arguments = afterSlash.dropFirst(name.count).drop(while: \.isWhitespace)
        return ParsedCommand(
            name: String(name),
            arguments: String(arguments),
            attachments: Array(blocks.dropFirst()))
    }

    /// Expands a `.prompt` template through the harness template engine
    /// into the turn's prompt text (plan.md §14.3). The template is
    /// data-sourced, so it renders untrusted, with the raw argument
    /// text under ``argumentsTemplateKey``.
    ///
    /// - Parameters:
    ///   - template: The command's template text.
    ///   - command: The parsed command carrying the arguments.
    /// - Returns: The expanded text.
    /// - Throws: `TemplateEngineError` when the render fails.
    static func expand(template: String, command: ParsedCommand) throws -> String {
        var context = TemplateContext()
        context.set(key: argumentsTemplateKey, to: .string(command.arguments))
        return try TemplateEngine(partials: nil).render(template, context: context, trust: .untrusted)
    }

    /// Assembles the model prompt of an expanded command turn: the
    /// expanded text first, then the text of each attached text block,
    /// newline-joined — the attachments carry into the expanded turn
    /// (plan.md §14.3). Non-text attachments ride in the echoed blocks,
    /// the same way they do for a plain prompt.
    ///
    /// - Parameters:
    ///   - expandedText: The expanded or rendered command text.
    ///   - attachments: The blocks after the command's text block.
    /// - Returns: The model prompt.
    static func modelPrompt(expandedText: String, attachments: [ContentBlock]) -> String {
        let trailingTexts = attachments.compactMap { block in
            if case .text(let content) = block {
                return content.text
            }
            return nil
        }
        return ([expandedText] + trailingTexts).joined(separator: "\n")
    }
}

// MARK: - The .action turn (plan.md §14.3)

/// One `.action` command turn: the closure runs and its text streams as
/// agent-message chunks. There is no model turn, and there are no
/// transcript entries beyond what the action records.
struct ActionCommandTurn: Sendable {
    /// The prompt's content blocks, echoed as the `user_message`.
    let promptBlocks: [ContentBlock]

    /// The turn-state owner of the session.
    let turnState: TurnStateOwner

    /// The sink every update of this turn goes to.
    let send: SessionUpdateSink

    /// The action closure of the command's body.
    let action: @Sendable (SlashCommand.Invocation) -> AsyncThrowingStream<String, Error>

    /// The invocation the action runs with.
    let invocation: SlashCommand.Invocation

    /// Runs the turn: the echo, `running`, the streamed chunks, and one
    /// `idle` with the stop reason. A stream error is classified the
    /// same way a model turn's error is (plan.md §8.2).
    func run() async {
        await send(
            .userMessage(
                UserMessage(
                    messageId: EventProjection.makeMessageId(), content: .value(promptBlocks))))
        await turnState.turnDidStart()
        let messageId = EventProjection.makeMessageId()
        var stop = TurnStop.completed
        do {
            for try await text in action(invocation) {
                await send(
                    .agentMessageChunk(
                        ContentChunk(content: .text(TextContent(text: text)), messageId: messageId)))
            }
        } catch {
            stop = PromptTurn.classify(error)
        }
        if await turnState.cancelRequested {
            stop = .cancelled
        }
        await turnState.turnDidEnd(reason: PromptTurn.stopReason(for: stop))
    }
}

// MARK: - The command refusals (plan.md §14.3)

extension RequestError {
    /// The reason an `.action` command with attachments reports: the
    /// action makes no model turn, so the attachments have no place to
    /// go, and silence would discard them.
    private static let actionAttachmentsReason =
        "an action command makes no model turn, so attached content has no place to go; send the attachments without the command"

    /// The unknown-command refusal (plan.md §14.3): invalid params with
    /// the name and the near-miss suggestions in `data`. It is never a
    /// model turn.
    ///
    /// - Parameters:
    ///   - name: The unknown command name.
    ///   - suggestions: The nearest command names, nearest first.
    /// - Returns: The typed invalid-params error.
    static func unknownCommand(name: String, suggestions: [String]) -> RequestError {
        let nearest = suggestions.map { "/\($0)" }.joined(separator: ", ")
        let message =
            suggestions.isEmpty
            ? "unknown command /\(name)"
            : "unknown command /\(name); the nearest is \(nearest)"
        return RequestError(
            code: .invalidParams,
            message: message,
            data: .object([
                "command": .string(name),
                "suggestions": .array(suggestions.map { .string($0) }),
            ]))
    }

    /// The `.action`-with-attachments refusal (plan.md §14.3): invalid
    /// params with the reason in `data`.
    ///
    /// - Parameter name: The action command's name.
    /// - Returns: The typed invalid-params error.
    static func actionCommandAttachments(name: String) -> RequestError {
        RequestError(
            code: .invalidParams,
            message: "/\(name) is an action command and cannot take attachments",
            data: .object([
                "command": .string(name),
                "reason": .string(actionAttachmentsReason),
            ]))
    }

    /// The command-expansion failure: a `.prompt` template that does
    /// not render, or a `.rendered` closure that throws. The error
    /// reaches the caller instead of becoming silently wrong model
    /// input.
    ///
    /// - Parameters:
    ///   - name: The command's name.
    ///   - underlying: The render error.
    /// - Returns: The typed internal error.
    static func commandExpansionFailed(name: String, underlying: any Error) -> RequestError {
        RequestError(
            code: .internalError,
            message: "/\(name) failed to expand",
            data: .object([
                "command": .string(name),
                "detail": .string(String(describing: underlying)),
            ]))
    }
}

// MARK: - Dispatch at the prompt owner (plan.md §14.3)

extension RoutedACPAgent {
    /// Dispatches one parsed command before anything touches the
    /// session (plan.md §14.3): a `.prompt` template expands through
    /// the harness engine, a `.rendered` closure is called — preferred
    /// wherever a provider offers it — and both feed a normal recorded
    /// model turn; an `.action` streams its text with no model turn. An
    /// unknown name refuses with near-miss suggestions.
    ///
    /// - Parameters:
    ///   - command: The parsed command.
    ///   - params: The prompt request the command arrived in.
    ///   - entry: The session's table entry.
    ///   - connection: The bound connection to notify through.
    /// - Returns: The empty acceptance.
    /// - Throws: `unknownCommand`, `actionCommandAttachments`, or
    ///   `commandExpansionFailed`.
    func dispatchCommand(
        _ command: ParsedCommand,
        params: PromptRequest,
        entry: ActiveSession,
        connection: AgentSideConnection
    ) async throws -> PromptResponse {
        guard let registered = await entry.commands.command(named: command.name) else {
            throw RequestError.unknownCommand(
                name: command.name,
                suggestions: await entry.commands.nearMisses(to: command.name))
        }
        switch registered.body {
        case .action(let action):
            guard command.attachments.isEmpty else {
                throw RequestError.actionCommandAttachments(name: command.name)
            }
            let (owner, send) = beginTurn(params: params, connection: connection)
            let turn = ActionCommandTurn(
                promptBlocks: params.prompt,
                turnState: owner,
                send: send,
                action: action,
                invocation: SlashCommand.Invocation(
                    arguments: command.arguments,
                    workingDirectory: entry.workingDirectory))
            let sessionId = params.sessionId
            connection.afterRespondingToCurrentRequest {
                await turn.run()
                await self.turnFinished(sessionId: sessionId)
            }
            return PromptResponse()
        case .prompt(let template):
            let expandedText: String
            do {
                expandedText = try CommandDispatch.expand(template: template, command: command)
            } catch {
                throw RequestError.commandExpansionFailed(name: command.name, underlying: error)
            }
            let (owner, send) = beginTurn(params: params, connection: connection)
            return scheduleModelTurn(
                overridePrompt: CommandDispatch.modelPrompt(
                    expandedText: expandedText, attachments: command.attachments),
                params: params, entry: entry, connection: connection, owner: owner, send: send)
        case .rendered(let render):
            // Mark the session busy before the async render, so a
            // concurrent prompt is refused instead of racing this one.
            let (owner, send) = beginTurn(params: params, connection: connection)
            let renderedText: String
            do {
                renderedText = try await render(
                    SlashCommand.Invocation(
                        arguments: command.arguments,
                        workingDirectory: entry.workingDirectory))
            } catch {
                turnFinished(sessionId: params.sessionId)
                throw RequestError.commandExpansionFailed(name: command.name, underlying: error)
            }
            return scheduleModelTurn(
                overridePrompt: CommandDispatch.modelPrompt(
                    expandedText: renderedText, attachments: command.attachments),
                params: params, entry: entry, connection: connection, owner: owner, send: send)
        }
    }
}
