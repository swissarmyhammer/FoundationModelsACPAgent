---
sessionId: 01M6KZ8ZMRTYGA0DVHSTNW7C7S
cwd: /Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent-wt-rec/Recordings/interrupted-nested-child/workspace/
updatedAt: '2026-11-04T19:06:20.699Z'
firstActivityAt: '2026-11-04T19:06:20.699Z'
additionalDirectories: []
agentID: leaf
agentName: leaf
tags: []
slot: standard
model: mlx-community/Qwen3.8-27B-mxfp4
context: 32768
instructions: '

  Do the task.

  '
recordingLevel: full
agentSpawn:
  parentSessionId: 01M6KZ8Z87G4B4DJXC5SWPVVVB
  parentToolCallId: 01M6KZ8Z8B8NB7GZB7GCCT13S8
  rootSessionId: 01M6KZ8Z4GXEZCXF3F53NAEBVM
routerId: 01M6KZ8WFKS7HYD9M9ATTG2P14
compactionCount: 0
profile:
  definitionName: acp-agent
  standard: mlx-community/Qwen3.8-27B-mxfp4
  flash: mlx-community/Qwen3-4B-4bit
  embedding: erjigit17/embeddinggemma-300m-ane-coreml
  context: 32768
configuration:
  instructions: '

    Do the task.

    '
  workingDirectory: file:///Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent-wt-rec/Recordings/interrupted-nested-child/workspace/
  recordingRoot: file:///Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent-wt-rec/Recordings/interrupted-nested-child/workspace/.acp-agent/transcripts/
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
    parentSessionId: 01M6KZ8Z87G4B4DJXC5SWPVVVB
    parentToolCallId: 01M6KZ8Z8B8NB7GZB7GCCT13S8
    rootSessionId: 01M6KZ8Z4GXEZCXF3F53NAEBVM
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
