---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: 'bench: stop the score step when docker does not run'
---
## The problem

`ensure_docker_host` in `bench/swebench_score.py` absorbs every error:

```python
    except Exception:
        pass
```

When docker does not run, `docker context inspect` still gives a path. The
script sets `DOCKER_HOST` to a socket that is not there, every instance fails,
and the script writes a report that says:

```json
"submitted": 16, "evaluated": 0, "resolved": 0, "errored": [ ... all 16 ... ]
```

That report reads like a failure of the agent. It is not. Docker was not
running.

## The work

1. Ask the docker daemon if it answers, before any other work. Use
   `docker info` or the `ping` of the docker library.
2. Stop with a clear message and a non-zero exit code when it does not answer.
   Say that docker must run, and name the socket the script tried.
3. Do not write a score report when no instance was evaluated.
4. Keep the behaviour that a build error of one instance is reported alone and
   is not part of the divisor. That behaviour is correct.

## When it is complete

- The score step stops at once when docker does not run.
- It writes no report in that condition.
- The message names the socket. #bench