---
position_column: done
position_ordinal: ffffffc080
title: Close the open thought and the open agent message at each boundary of the model order
---
Request from TestudoApp (Testudo card ^ras4xe9, user decision 2026-11-23). FoundationModelsRouter 1173a869 streams reasoningDelta live, before the toolCall and the textDelta of its round. ACPEventTranslator.project(_:) keeps one thoughtMessageId and one agentMessageId, so a thought after a tool call goes into the first thought.

Fix: close the open thought (thoughtMessageId = nil) on .toolCall and .textDelta. Close the open agent message (agentMessageId = nil) on .toolCall and .reasoningDelta.

Tests: thought, tool call, thought, message → agent_thought_chunk (id X), tool_call, agent_thought_chunk (id Y, not X), agent_message_chunk. session/resume replays the same order.