---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4xb5rna9p9tszmqm0tv1aaj
  text: |-
    T0 report.

    Packages: Router fc5acc3b, Extras e454d7c, Agents 55aeae7 (Agents main has only a kanban commit after it). Multitool 889e0f2. Package.resolved is gitignored and all family pins are `branch: main`. Extras main is now d0d4653 (RunClock); I keep e454d7c until the step lead gives the Router head that uses it.

    Build: fails. The compiler stops at the first failed file (SessionFollowUp.swift:31: AsyncStream<SessionOutput> is not AsyncStream<SessionEvent>), also with -continue-building-after-errors. The list of breaks below comes from a search of the consumer code.

    Breaks in Sources:
    - SessionFollowUp.swift:31: streamSessionEvents() gives SessionOutput.
    - PromptExecution.swift:262: streamEvents(to:) (helper, still exists) into drive; drive reads SessionEvent.
    - PromptExecution.swift:1145, SessionLifecycle.swift:151: session.cancel() is removed; use cancelAll() (nonisolated, returns SignalID, does not wait).
    - BuiltinCommands.swift:281-296: compact() returns SignalID at once, not CompactionResult.
    - CompactionReporter: reportStart/reportEnd/makeCompactionId take the old result (removed in T4).
    - AgentsComposition.swift:118: RunEventObserver is now (AgentRun, SessionOutput); recordAgentRunEvent must take SessionOutput.
    - Sources use `any RoutedSession` already. ACPAgent does not call AgentRun.deliver.

    Breaks in Tests:
    - CloseCountingRoutedSession: fork returns `RoutedSession` (must be `any`); compact, cancel(), drain(), cancel(message:), send (now nonisolated, throws, MailID), pendingMessages ([Mail]), replace(id:prompt:), messageQueueDepth are old; new requirements mail(_:), cancel(_:), cancelAll(), replace(_:with:), awaitTerminal(of:) x2, awaitAnswer(of:), mailQueueDepth(), streamSessionEvents() -> AsyncStream<SessionOutput>. The nonisolated requirements can forward to the wrapped session.
    - Other tests: messageIds (4), messageQueueDepth (2), drain (1 + 2 in IntegrationTests), cancel(message:) (2), replace(id:) (2), pendingMessages (2), MessageID (4), CompactionResult from compact (2).
    - Tests: 298 .timeLimit, about 41 clock lines. IntegrationTests: 14 .timeLimit, about 57 clock lines. EvaluationTests: 0.

    API against mailbox.md sections 3-5 (consumer view): agrees. RoutedSession refines MailSink (Event == SessionOutput); SessionOutput {origin, event}; signals cancel(id), cancelAll(), replace(id, with:), compact(prompt:budget:) are nonisolated and return SignalID; awaitTerminal(of: MailID/SignalID), awaitAnswer(of:); events cancelled, signalDone, lost, mailDelivered; CompactionReason.requested; respond(to:), streamEvents(to:), streamResponse(to:) stay as helpers. Differences already recorded in the Progress table (send is synchronous and throws; compaction ids are String = SignalID.description).

    ACP messageId: MessageId is a free String (rawValue). PromptRequest has no client messageId. The agent already makes ULID message ids. Thus MailID.description is a valid ACP messageId: no question.

    Gaps for elicitation-plan phase 1 (no code changed):
    G1 (task 2 / T5): needs Router 9 and 10. awaitIdle() is event driven, but it is not in order with streamSessionEvents(): an idle from awaitIdle() can go to the client before the last buffered events of the answer. And a run that waits only for the user keeps awaitIdle() from return (Router 9). Thus running/idle from Router work needs a Router working/idle event on the output (task 10).
    G2 (task 43 / T3): the headless CLI is an ACP client (RunPrompt reads session/update and stops at the first idle). The wire has no terminal for each messageId. Question: what must the wire carry so the CLI knows the end of its own MailID? Option A: the first idle after the echo of its own messageId (the text of task 43). Option B: an idle update with `_meta` that names the ended mail ids.
    G3 (task 3 / T3): mail(_:) can throw (closed session, duplicate id) after the session/prompt response is sent, but ACP forbids an error after insertion. Proposal: the projector then sends idle with an error stop reason and the error text as an agent message.
    G4 (tasks 4, 5, 17): no output event tells ACPAgent that Router rejected an open elicitation (cancelAll, close, run cancel). With a relay for the whole session, the elicitation/create request to the client then stays open. Today promptFinished ends it. Needs Extras 17 and an event, or a relay rule. Not in the mail plan.
    G5 (task 1): AnswerFailure on the stream has only cancelled | error(String). The typed error (refusal, context size) comes from awaitAnswer(of:). The projector can call awaitAnswer(of:) inline when it reads the terminal (it returns at once), so the order stays. No Router work.
    G6 (T4): session/cancel ends with idle + cancelled when the projector reads signalDone of the cancelAll SignalID. If a compaction runs, cancelAll runs after it (signals in order), so the idle comes late. This follows the plan; I note it only.
  timestamp: 2026-10-14T13:56:04.394100+00:00
position_column: done
position_ordinal: ffca80
title: 'T0: Check steps 2 and 3 (packages, build, API against mailbox.md)'
---
Step 4 of the mail work, part T0.

Read first: ../mailbox.md (sections 3, 4, 5, the signals table, section 8 rows 2, 3 and 4, and the Progress table) and ../elicitation-plan.md (sections 7, 8 and 9, phase 1). All items in mailbox.md are decisions.

Package heads (all on main): Router fc5acc3b or later (parts G, H, I: run event origins `.mail([id])`, `awaitAnswer(of:)`, `TerminalLookupError`), Extras e454d7c, Agents 55aeae7.

Work:
- Resolve the packages. Build ACPAgent. Make a list of each break.
- From the view of a consumer, compare the public Router API and the public Agents API with mailbox.md sections 3 to 5. Make a list of each difference.
- Find which ACPAgent tasks of elicitation-plan.md phase 1 (tasks 1 to 5, 49 and 43) need Router or Extras work that is not in the mail plan (Router tasks 9 to 11, Extras tasks 15 to 17).
- Report each gap to the step lead before you change code for it.

Rules for all of step 4:
- Write all text (comments, docs, commits, reports, tasks) in STE.
- Commit after each task, with ACPAgent green. Report after each task: the commit, the test result, and each difference from the plan with its reason. Do not push until the step lead accepts step 4.
- Run the full test suite one time. Do not run tests again and again to find a failure. A test that fails only sometimes is a bad test: find the cause and make it deterministic, or fix the race in the code. Do not use .timeLimit, sleep, clock wait, poll or retry. If a test hangs, take a `sample <pid>` of your own test process before you stop it. Stop only your own process ids (never pkill or a pattern kill).
- If a decision is not in the plan, ask the step lead before you write the code. #mail-step-4