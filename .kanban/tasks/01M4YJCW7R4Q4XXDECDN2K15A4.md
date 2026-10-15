---
assignees:
- claude-code
position_column: done
position_ordinal: ffd680
title: 'Bad test: noProcessOfTheChildsGroupOutlivesTheRun reads the child''s group by pid after the run'
---
Found in the check of ^8fs1pz6. Step lead decision: a separate task and its own commit, after ^8fs1pz6 is pushed.

Problem: OutOfProcessTests.noProcessOfTheChildsGroupOutlivesTheRun reads ProcessCensus.isProcessGroupAlive(leader: child) (killpg with signal 0) after the run ended. The child is reaped at that time, so the system can give its pid to a new process group leader. Then the read says "alive" after a correct run. The test can fail by chance.

Fix: hold a handle that cannot be reused, or prove the end of each member with its exit event. For example, arm a kernel exit source on each member of the group while the child is alive, and the end of the waits is the result. No read of the pid after the run.

Check: one IntegrationTests full run, green. #tests #mail-step-4