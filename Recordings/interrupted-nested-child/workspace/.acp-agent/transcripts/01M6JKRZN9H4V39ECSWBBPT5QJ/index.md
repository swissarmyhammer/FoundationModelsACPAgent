---
sessionId: 01M6JKRZN9H4V39ECSWBBPT5QJ
cwd: /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Recordings/interrupted-nested-child/workspace/
updatedAt: '2026-11-04T06:26:07.669Z'
firstActivityAt: '2026-11-04T06:26:07.669Z'
additionalDirectories: []
agentID: leaf
agentName: leaf
tags: []
slot: standard
model:
  repo: mlx-community/Qwen3.8-27B-4bit
  drafter: mlx-community/Qwen3.8-27B-MTP-4bit
context: 32768
instructions: '

  Do the task.

  '
recordingLevel: full
agentSpawn:
  parentSessionId: 01M6JKRZA4NJBNESVN3DV9T2KY
  parentToolCallId: 01M6JKRZA75RS90H9Y5YSW904Q
  rootSessionId: 01M6JKRZ7HWFCD7GFPEETKGX83
routerId: 01M6JKRY71VK8CV4VEJ52V229Q
compactionCount: 0
profile:
  definitionName: acp-agent
  standard:
    repo: mlx-community/Qwen3.8-27B-4bit
    drafter: mlx-community/Qwen3.8-27B-MTP-4bit
  flash: mlx-community/Qwen3-4B-4bit
  embedding: erjigit17/embeddinggemma-300m-ane-coreml
  context: 32768
configuration:
  instructions: '

    Do the task.

    '
  workingDirectory: file:///Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Recordings/interrupted-nested-child/workspace/
  recordingRoot: file:///Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Recordings/interrupted-nested-child/workspace/.acp-agent/transcripts/
  toolNames:
  - runCode
  - searchTools
  - skills
  - agents
  budget:
    limit: 32768
    trigger: 0.8
    target: 0.5
  compactionPrompt:
    name: router-default-v7
    text: 'Summarize the conversation above. Whoever continues has no other memory
      of it.

      Start with a line "Values:" that gives each code, name, path and number the
      user asked to keep or the next step needs, copied exactly.

      Then write a short summary of the few points that matter to go on:

      - what the user wants;

      - what is decided, and what must not be done;

      - what is done, and what comes next.


      Leave out small talk, and finished work that does not matter next. Use plain
      sentences or short bullets.'
  agentSpawn:
    parentSessionId: 01M6JKRZA4NJBNESVN3DV9T2KY
    parentToolCallId: 01M6JKRZA75RS90H9Y5YSW904Q
    rootSessionId: 01M6JKRZ7HWFCD7GFPEETKGX83
  repetitionDetection:
    isEnabled: true
    windowTokens: 2048
    minimumLineLength: 20
    recoveriesPerTurn: 2
    passTokenLimit: 16384
    comparesLineShapes: true
    shortLineRepeatThreshold: 8
    reasoningTokenLimit: 8192
    identicalToolCallLimit: 3
  mailOnlyAnswerLimit: 100
  inlineSettleGrace: 6.0
  userPresence: headless
schemaVersion: 3
---
