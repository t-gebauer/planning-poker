# Planning Poker

Minimalistic planning poker web application.

Only one session at a time.

Every user can reveal and clear the current cards.
But users can only set their own card value.

## Run

```sh
./build && planning-poker.exe -p 8080 -- localhost
```

Then visit http://localhost:8080/planning-poker/

## Development

### Docs

https://redbean.dev

### IPC: shared memory

Redbean handles each request in a separate process. State needs to be shared
across process boundaries.

Initially, I used sqlite3 (with journal_mode=WAL) for inter-process
communication, as recommended by redbean devs.
But at some point on one worker `step()` would always return `BUSY`, which could
only be solved by re-opening the database, which would sometimes cause another
problem: "attempt to use closed virtual machine".

With shared memory the whole backend is a lot simpler, (and maximally fast),
as long as the lock works correctly.

### Use of memory.wait

The /status request waits for a few seconds and returns as soon as the status changes.
This effectively pushes the new status immediately to all listeners.
BUT memory.wait is not interupted when the client leaves, so we cannot wait endlessly
to minimize the effect of stale connections.
Additionally, /status is also used to update the last-seen time of the users,
which requires frequent requests anyway.
